import Foundation

/// Antigravity(`agy`) 작업 에이전트 실측. 임시 프로젝트에서 실제 턴을 돌린다.
///
/// 이 어댑터는 승인을 물을 수 없어 자동 승인으로만 동작하므로,
/// **프로젝트별 허용이 없으면 보내지지 않는 것**부터 확인한다.
/// Gemini flash-low 턴 2회(파일 편집 1회 + 세션 재개 1회)를 쓴다.
enum AntigravityLiveTests {
    @MainActor
    static func run(_ t: TestKit) async {
        await t.group("Antigravity 작업 에이전트")
        let root: URL
        do {
            root = try TestEnv.makeTempProject("antigravity")
        } catch {
            await t.check("임시 프로젝트 생성", false, "\(error)")
            return
        }
        defer { TestEnv.cleanup(root) }
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let seed = projectDir.appendingPathComponent("seed.txt")
        try? "hello\n".write(to: seed, atomically: true, encoding: .utf8)

        let store = Store(databaseURL: root.appendingPathComponent("handoff.sqlite3"))
        let model = AppModel(store: store)
        await model.bootstrap()
        await t.check("앱 모델 부트스트랩", model.bootstrapError == nil, model.bootstrapError ?? "")
        guard model.bootstrapError == nil else { return }
        guard model.cliStatus[.gemini]?.isUsable == true else {
            await t.check("agy 실행 가능", false, model.cliStatus[.gemini]?.error ?? "상태 없음")
            return
        }
        await t.check("agy 실행 가능", true, model.cliStatus[.gemini]?.resolvedPath ?? "")

        let project = await model.addProject(name: "antigravity", path: projectDir.path)
        var thread = await model.addThread(projectID: project.id, title: "Antigravity 시험")
        thread.preferredProvider = .gemini
        await model.updateThread(thread)

        // 모델 목록은 CLI 에서 조회한 값만 쓴다.
        let scope = AgentScope(provider: .gemini, accountID: "")
        await model.refreshModelCatalog(scope)
        let options = model.options(for: scope)
        await t.check("agy 모델 목록 조회", !options.isEmpty,
                      options.map(\.identifier).prefix(3).joined(separator: ", "))
        let flash = options.first { $0.identifier.contains("flash") } ?? options.first
        if let flash {
            await model.setModelSelection(ModelSelection(model: flash.identifier, effort: "low"),
                                          for: .gemini)
            await t.check("강도 목록에 boost 포함", flash.supportedEfforts.contains("boost"),
                          flash.supportedEfforts.joined(separator: " · "))
        }

        // 1) 프로젝트 허용 전에는 보내지 않는다.
        let blocked = await model.send("seed.txt 를 읽어줘", provider: .gemini, threadID: thread.id)
        await t.check("허용 전에는 보내지 않음", blocked == false && model.banner?.isError == true,
                      model.banner?.text ?? "")

        // 2) 허용한 뒤 실제 턴.
        model.setAntigravityAllowed(true, projectID: project.id)
        model.banner = nil
        let sent = await model.send(
            "seed.txt 를 읽고 같은 폴더에 greet.txt 를 만들어 첫 줄 뒤에 \" world\" 를 붙인 내용으로 채워줘.",
            provider: .gemini, threadID: thread.id)
        await t.check("허용 후 전송 시작", sent, model.banner?.text ?? "")
        guard sent else { return }
        let finished = await wait(300) { !model.runner.isBusy }
        let runs = ((try? await store.runs(threadID: thread.id)) ?? []).sorted { $0.startedAt < $1.startedAt }
        let events = (try? await store.events(threadID: thread.id)) ?? []
        await t.check("턴 완료", finished && runs.last?.state == .completed,
                      "\(runs.last?.state.koreanName ?? "기록 없음") · \(runs.last?.errorMessage ?? "")")
        let greet = (try? String(contentsOf: projectDir.appendingPathComponent("greet.txt"),
                                 encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        await t.equal("파일을 실제로 만듦", greet ?? "없음", "hello world")
        await t.check("파일 변경이 기록됨",
                      events.contains { $0.kind == .fileChange && $0.title.contains("greet.txt") },
                      events.filter { $0.kind == .fileChange }.count.description + "건")
        // 화면은 toolUseID 로 시작·완료를 한 항목으로 합친다 (Codex 와 같은 방식).
        let fileStates = events.filter { $0.kind == .fileChange }
            .compactMap { JSONUtil.object($0.payloadJSON ?? "")?["status"] as? String }
        await t.check("시작·완료 상태를 화면 어휘로 기록",
                      fileStates.contains("inProgress") && fileStates.contains("completed"),
                      fileStates.joined(separator: " → "))
        await t.check("자동 승인 사실을 대화에 남김",
                      events.contains { $0.kind == .systemNotice && $0.text.contains("승인을 묻지 않고") })
        await t.check("응답 본문 기록",
                      events.contains { $0.kind == .agentMessage && $0.provider == .gemini
                                        && !$0.text.isEmpty })
        let usage = ((try? await store.usage(threadID: thread.id)) ?? [])
            .first { $0.runID == runs.last?.id }
        await t.check("사용량 기록", (usage?.inputTokens ?? 0) > 0,
                      "입력 \(usage?.inputTokens ?? 0) · 출력 \(usage?.outputTokens ?? 0)")
        let session = ((try? await store.sessions(threadID: thread.id)) ?? [])
            .first { $0.provider == .gemini }
        await t.check("대화 ID 저장", (session?.cliSessionID?.isEmpty == false),
                      session?.cliSessionID ?? "없음")

        // 3) 세션 재개 — 같은 대화 ID 로 이어간다.
        let resumed = await model.send("방금 만든 파일 이름만 한 줄로 답해줘. 도구는 쓰지 마.",
                                       provider: .gemini, threadID: thread.id)
        _ = await wait(300) { !model.runner.isBusy && resumed }
        let after = (try? await store.events(threadID: thread.id)) ?? []
        let reply = after.last { $0.kind == .agentMessage && $0.provider == .gemini }
        await t.check("이전 맥락을 이어감", reply?.text.contains("greet.txt") == true,
                      reply.map { String($0.text.prefix(80)) } ?? "응답 없음")
        let sessionAfter = ((try? await store.sessions(threadID: thread.id)) ?? [])
            .first { $0.provider == .gemini }
        await t.equal("같은 대화 ID 유지", sessionAfter?.cliSessionID ?? "", session?.cliSessionID ?? "-")
        // 4) 한도 — 프로젝트에서 허용했으니 `agy -p /usage`(모델을 부르지 않는 명령)로 읽는다. 창은 모델 묶음(Gemini · Claude · GPT)
        //    마다라 계정 전체 창이 아니다. 허용한 순간 · 실행이 끝날 때 뒤에서 읽으므로, 때에 따라 갈리지 않게 여기서 새로 읽어 본다.
        await t.check("허용하면 한도를 읽는다", model.limits.antigravityEnabled)
        await model.limits.refresh(scope, force: true)
        let limit = model.limits.snapshot(scope)
        await t.check("한도를 agy -p /usage 로 읽음 — 모델 묶음마다의 창",
                      limit.hasUsableData && !limit.windows.isEmpty && limit.windows.allSatisfy { $0.model != nil },
                      limit.hasUsableData
                        ? limit.windows.map { "\($0.label) \(Fmt2.pct($0.utilization))" }.joined(separator: ", ")
                        : (limit.message ?? "정보 없음"))
        await store.db.close()
    }

    @MainActor
    private static func wait(_ timeout: TimeInterval, until condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
        return await condition()
    }
}
