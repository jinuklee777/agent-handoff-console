import Foundation

/// 턴 옵션의 실제 CLI 검증 (`inttest turnoptions`). 실제 어댑터와 `RunCoordinator` 를 거친다.
/// 제공자마다 두 턴: 읽기 전용 + 출력 스키마 턴이 파일을 쓰지 못하고 구조화 응답을 돌려주는지,
/// 그 뒤 **같은 세션을 재개한** 보통 턴은 파일을 쓰는지 (읽기 전용이 뒤 턴으로 새지 않는지).
/// 모델은 싼 것으로 고정한다. Codex 의 astra 는 쓰지 않는다.
enum TurnOptionsLiveTests {

    static let claudeModel = "haiku"
    static let codexModel = "gpt-5.6-terra"

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["created","note"],\
    "properties":{"created":{"type":"boolean"},"note":{"type":"string"}}}
    """

    @MainActor
    static func run(_ t: TestKit, _ e: LiveTests.Env) async {
        await t.group("턴 옵션 · 실제 CLI")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-turnopt-\(UUID().uuidString).sqlite3")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }
        let store = Store(databaseURL: dbURL)
        do { try await store.bootstrap() } catch {
            await t.check("저장 계층 준비", false, "\(error)")
            return
        }
        let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
        coordinator.claudePermissionMode = "acceptEdits"
        coordinator.codexSandboxMode = "workspace-write"
        coordinator.codexApprovalPolicy = "on-request"
        await coordinator.loadPrices()
        let probe = CoordinatorProbe(coordinator: coordinator)
        probe.onApproval = { request, c in Task { await c.respond(approval: request, decision: .allow) } }
        coordinator.delegate = probe

        let project = Project(name: "turnoptions", path: e.root.path)
        try? await store.upsertProject(project)

        for provider in [AgentProvider.claude, .codex] {
            let name = provider.displayName
            var thread = ConversationThread(projectID: project.id, title: "턴 옵션 \(name)")
            if provider == .claude {
                thread.claudeSelection = ModelSelection(model: claudeModel, effort: nil)
            } else {
                thread.codexSelection = ModelSelection(model: codexModel, effort: "low")
            }
            try? await store.upsertThread(thread)

            let blocked = e.root.appendingPathComponent("ro_\(provider.rawValue).txt")
            let written = e.root.appendingPathComponent("rw_\(provider.rawValue).txt")
            try? FileManager.default.removeItem(at: blocked)
            try? FileManager.default.removeItem(at: written)

            // 1) 읽기 전용 + 출력 스키마
            let approvalsBefore = probe.attentions.filter { $0.1 == .approvalNeeded }.count
            let finishedBefore = probe.finished.count
            do {
                try await coordinator.send(
                    prompt: "\(blocked.path) 파일을 만들고 HELLO 라고 쓰세요. 도구나 셸을 써서 실제로 시도하세요. "
                        + "파일이 만들어졌는지를 created 에, 한 줄 설명을 note 에 넣으세요.",
                    thread: thread, project: project, provider: provider,
                    turn: AgentTurnOptions(readOnly: true, outputSchema: schema))
            } catch {
                await t.check("\(name): 읽기 전용 턴 시작", false, "\(error)")
                continue
            }
            await t.check("\(name): 읽기 전용 턴 종료", await probe.waitUntilIdle())
            guard probe.finished.count > finishedBefore, let done = probe.finished.last else {
                await t.check("\(name): 읽기 전용 턴 완료 통지", false)
                continue
            }
            await t.equal("\(name): 읽기 전용 턴 완료 상태", done.1.state, .completed)
            await t.check("\(name): 읽기 전용 턴은 파일을 만들지 못한다", !FileManager.default.fileExists(atPath: blocked.path))
            await t.equal("\(name): 읽기 전용 턴은 승인을 묻지 않는다",
                          probe.attentions.filter { $0.1 == .approvalNeeded }.count, approvalsBefore)
            let parsed = done.1.structuredOutput.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            await t.check("\(name): 구조화 응답이 스키마의 필드를 갖는다",
                          parsed?["created"] is Bool && parsed?["note"] is String, done.1.structuredOutput ?? "nil")
            await t.equal("\(name): created=false", parsed?["created"] as? Bool, false)
            await t.check("\(name): astra 를 쓰지 않았다", !(done.0.model ?? done.1.model ?? "").lowercased().contains("astra"),
                          done.1.model ?? "")

            // 2) 같은 세션을 재개한 보통 턴은 쓴다
            let session = try? await store.session(threadID: thread.id, provider: provider, accountID: "")
            await t.check("\(name): 세션 저장", session?.cliSessionID != nil)
            do {
                try await coordinator.send(
                    prompt: "\(written.path) 파일을 만들고 HELLO 라고 쓰세요. 끝나면 DONE 이라고만 답하세요.",
                    thread: thread, project: project, provider: provider)
            } catch {
                await t.check("\(name): 쓰기 턴 시작", false, "\(error)")
                continue
            }
            await t.check("\(name): 쓰기 턴 종료", await probe.waitUntilIdle())
            await t.check("\(name): 읽기 전용 뒤의 쓰기 턴은 파일을 만든다 (읽기 전용이 새지 않는다)",
                          FileManager.default.fileExists(atPath: written.path))
            let after = try? await store.session(threadID: thread.id, provider: provider, accountID: "")
            await t.equal("\(name): 같은 세션을 재개했다", after?.cliSessionID, session?.cliSessionID)
            await t.check("\(name): 스키마를 주지 않은 턴은 구조화 응답이 없다", probe.finished.last?.1.structuredOutput == nil)
        }

        await planningTurns(t, coordinator: coordinator, probe: probe, store: store, project: project)
    }

    /// 계획 스키마(`PlanSchema`)를 실제 계획 턴에 넘긴다: 두 CLI 가 스키마를 받아들이고,
    /// 돌아온 계획이 앱의 검사(`PlanValidator`)를 통과하는지. 읽기 전용으로 돈다.
    @MainActor
    private static func planningTurns(_ t: TestKit, coordinator: RunCoordinator, probe: CoordinatorProbe,
                                      store: Store, project: Project) async {
        await t.group("계획 스키마 · 실제 CLI")
        let request = "설정 창을 열었다 닫으면 가끔 크래시가 납니다. 원인을 찾아 고치고 회귀 테스트를 추가해 주세요."
        let prompt = """
        당신은 코딩 작업의 계획 담당입니다. 파일을 읽거나 바꾸지 말고 아래 요청만 보고 작업 계획을 세우세요.
        단순한 요청은 작업 하나로 두고 억지로 쪼개지 마세요. 작업은 최대 8개입니다.
        의존 관계는 dependsOn 에 작업 id 로 적고, 작업마다 완료 조건(acceptance)과 검증 방법(verification)을 반드시 적으세요.
        프로젝트: macOS SwiftUI 앱.

        요청: \(request)
        """
        for provider in [AgentProvider.claude, .codex] {
            let name = provider.displayName
            var thread = ConversationThread(projectID: project.id, title: "계획 \(name)")
            if provider == .claude {
                thread.claudeSelection = ModelSelection(model: claudeModel, effort: nil)
            } else {
                thread.codexSelection = ModelSelection(model: codexModel, effort: "low")
            }
            try? await store.upsertThread(thread)
            let before = probe.finished.count
            do {
                try await coordinator.send(prompt: prompt, thread: thread, project: project, provider: provider,
                                           turn: AgentTurnOptions(readOnly: true, outputSchema: PlanSchema.jsonString))
            } catch {
                await t.check("\(name): 계획 턴 시작", false, "\(error)")
                continue
            }
            await t.check("\(name): 계획 턴 종료", await probe.waitUntilIdle())
            guard probe.finished.count > before, let done = probe.finished.last else {
                await t.check("\(name): 계획 턴 완료 통지", false)
                continue
            }
            await t.equal("\(name): CLI 가 계획 스키마를 받아들였다", done.1.state, .completed)
            var output = done.1.structuredOutput
            // 계획 보정 1회: 거절 사유를 같은 세션에 돌려주고 다시 받는다.
            if case .failure(let rejection) = PlanValidator.accept(output) {
                await t.note("\(name): 첫 계획 거절 → 보정 요청: " + rejection.issues.map(\.message).joined(separator: " / "))
                let count = probe.finished.count
                do {
                    try await coordinator.send(prompt: rejection.feedback, thread: thread, project: project, provider: provider,
                                               turn: AgentTurnOptions(readOnly: true, outputSchema: PlanSchema.jsonString))
                    _ = await probe.waitUntilIdle()
                    if probe.finished.count > count { output = probe.finished.last?.1.structuredOutput }
                } catch {
                    await t.check("\(name): 보정 턴 시작", false, "\(error)")
                }
            }
            switch PlanValidator.accept(output) {
            case .success(let plan):
                await t.check("\(name): 계획이 앱의 검사를 통과 (보정 1회 이내)", true,
                              "작업 \(plan.tasks.count)개: " + plan.tasks.map { "\($0.id)[\($0.kind.rawValue)/\($0.difficulty)]" }.joined(separator: " "))
                await t.check("\(name): 실행 순서를 정할 수 있다", PlanValidator.executionOrder(plan.tasks) != nil)
            case .failure(let rejection):
                await t.check("\(name): 계획이 앱의 검사를 통과 (보정 1회 이내)", false,
                              rejection.issues.map(\.message).joined(separator: " / ") + " ← " + (output ?? "nil").prefix(300))
            }
        }
    }
}
