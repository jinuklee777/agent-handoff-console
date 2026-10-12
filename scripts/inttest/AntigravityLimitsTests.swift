import Foundation

// MARK: - Antigravity 한도: `agy -p /usage --output-format json` 해석 · 모델 묶음 · 읽는 조건 · 화면 줄

/// 예전(2026-09-12, agy 1.2.1)에는 `/usage` 가 대화형 명령뿐이라고 보고 Antigravity 한도를 늘 "정보 없음" 으로 두었다. agy 1.3.2 에서
/// `agy -p /usage --output-format json` 이 토큰 0 으로 묶음별 한도를 돌려주는 것을 확인했다 (2026-10-09). v0.1 은 보이기만 한다 —
/// 자동 인계 · 이어 가기의 대상은 아니다 (사용자 결정 2026-10-09).
@MainActor
enum AntigravityLimitsTests {
    static func run(_ t: TestKit) async {
        await parsing(t)
        await groups(t)
        await presentation(t)
        await fetching(t)
        await service(t)
        await appModel(t)
    }

    /// 2026-10-09 이 Mac 의 실제 응답 (agy 1.3.2, 빈 임시 폴더에서).
    static let sample = #"""
    {"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-15T06:55:15Z\nGemini Models\tFive Hour Limit Remaining\t100%\t2026-10-09T19:04:20Z\nClaude and GPT models\tWeekly Limit Remaining\t100%\t2026-10-16T14:07:01Z\nClaude and GPT models\tFive Hour Limit Remaining\t100%\t2026-10-09T19:07:01Z\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit and a 5-hour limit.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","description":"You have used some of your weekly limit, it will fully refresh in 5 days, 16 hours.","window":"weekly","remaining_fraction":0.9973227381706238,"reset_time":"2026-10-15T06:55:15Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","description":"You have used some of your 5-hour limit, it will fully refresh in 4 hours, 57 minutes.","window":"5h","remaining_fraction":0.9989356994628906,"reset_time":"2026-10-09T19:04:20Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-16T14:07:01Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-10-09T19:07:01Z"}]}]}}}
    """#

    /// 묶음별 남은 비율 · 초기화 시각으로 응답을 짓는다 (초기화는 지금부터 n 시간 뒤).
    static func response(gemini: (h5: Double, week: Double), other: (h5: Double, week: Double), now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        func bucket(_ id: String, _ window: String, _ remaining: Double, hours: Double) -> String {
            #"{"id":"\#(id)","name":"x","window":"\#(window)","remaining_fraction":\#(remaining),"reset_time":"\#(iso.string(from: now.addingTimeInterval(hours * 3600)))"}"#
        }
        return #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":["#
            + #"{"name":"Gemini Models","buckets":["# + bucket("gemini-weekly", "weekly", gemini.week, hours: 100) + ","
            + bucket("gemini-5h", "5h", gemini.h5, hours: 3) + "]},"
            + #"{"name":"Claude and GPT models","buckets":["# + bucket("3p-weekly", "weekly", other.week, hours: 120) + ","
            + bucket("3p-5h", "5h", other.h5, hours: 4) + "]}]}}}"
    }

    static func parse(_ raw: String) -> LimitSnapshot {
        var base = LimitSnapshot(provider: .gemini)
        base.fetchedAt = Date()
        return LimitsFetcher.parseAntigravityUsageResponse(raw, into: base)
    }

    private static func parsing(_ t: TestKit) async {
        await t.group("Antigravity 한도: 해석")
        let snap = parse(sample)
        await t.equal("실측 응답: 정상", snap.status, .ok)
        await t.equal("창 넷 — 묶음마다 짧은 창 먼저", snap.windows.map(\.label),
                      ["Gemini 5시간", "Gemini 7일", "Claude · GPT 5시간", "Claude · GPT 7일"])
        await t.equal("묶음 이름은 모델 한도로 (계정 전체 한도가 아니다)", snap.windows.map { $0.model ?? "-" },
                      ["Gemini", "Gemini", "Claude · GPT", "Claude · GPT"])
        await t.equal("창 길이", snap.windows.map { $0.spanMinutes ?? 0 }, [300, 10080, 300, 10080])
        let geminiWeek = snap.windows[1].utilization ?? -1
        await t.check("사용률 = 1 − 남은 비율 (반올림한 글이 아니라 구조의 값)", abs(geminiWeek - (1 - 0.9973227381706238)) < 1e-9,
                      "\(geminiWeek)")
        await t.equal("초기화 시각", snap.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-10-09T19:04:20Z"))
        await t.check("묶음 한도는 계정 전체 한도 도달로 세지 않는다", !snap.reachedAccountWideCap)

        let fresh = parse(response(gemini: (1, 1), other: (1, 1)))
        await t.check("모두 100% 남음도 그대로 믿는다 (사용률 0 · 정상 — 사용자 결정 2026-10-09)",
                      fresh.status == .ok && fresh.windows.count == 4 && fresh.windows.allSatisfy { $0.utilization == 0 })

        let oneFull = parse(response(gemini: (0, 0.3), other: (0.8, 0.9)))
        await t.check("한 묶음만 찼으면 정상 (다른 묶음 모델은 쓸 수 있다)", oneFull.status == .ok && !oneFull.reachedAccountWideCap)
        let bothFull = parse(response(gemini: (0, 0.3), other: (0.5, 0)))
        await t.equal("모든 묶음에 다 찬 창이 있으면 한도 도달", bothFull.status, .subscriptionCap)

        let failed = parse(#"{"status":"ERROR","error":"You are not logged in. Run agy to sign in.","response":""}"#)
        await t.check("실패 응답: 인증 문제로 · 원문을 남긴다", failed.status == .authProblem && failed.rawResponse != nil
                        && (failed.message ?? "").contains("not logged in"), failed.message ?? "")
        let garbage = parse("Unknown command: /usage")
        await t.check("JSON 이 아니면 정보 없음 + 원문 (0% 로 채우지 않는다)", garbage.status == .noData && garbage.windows.isEmpty
                        && garbage.rawResponse == "Unknown command: /usage")
        let noGroups = parse(#"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[]}}}"#)
        await t.check("묶음이 없으면 정보 없음", noGroups.status == .noData && noGroups.windows.isEmpty)

        let textOnly = parse(#"{"status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t40%\t2026-10-15T06:55:15Z\nGemini Models\tFive Hour Limit Remaining\t90%\t2026-10-09T19:04:20Z\n"}"#)
        await t.equal("구조가 없으면 글에서 (묶음 · 창 · %)", textOnly.windows.map(\.label), ["Gemini 5시간", "Gemini 7일"])
        await t.check("글의 % 는 남은 비율", abs((textOnly.windows[1].utilization ?? 0) - 0.6) < 1e-9)
        await t.equal("epoch 초도 시각으로", LimitsFetcher.antigravityDate(NSNumber(value: 1_760_000_000)),
                      Date(timeIntervalSince1970: 1_760_000_000))
    }

    private static func groups(_ t: TestKit) async {
        await t.group("Antigravity 한도: 모델 묶음")
        await t.equal("모델을 고르지 않았으면 앱 기본(Gemini Flash)의 묶음", LimitsFetcher.antigravityGroup(ofModel: nil), "Gemini")
        await t.equal("gemini-… → Gemini", LimitsFetcher.antigravityGroup(ofModel: "gemini-3.8-flash-high"), "Gemini")
        await t.equal("claude-… → Claude · GPT", LimitsFetcher.antigravityGroup(ofModel: "claude-sonnet-4-6"), "Claude · GPT")
        await t.equal("gpt-oss-… → Claude · GPT", LimitsFetcher.antigravityGroup(ofModel: "gpt-oss-120b"), "Claude · GPT")
        await t.equal("모르는 묶음은 끝의 models 만 뗀다", LimitsFetcher.antigravityGroupName("Llama Models"), "Llama")

        let snap = parse(response(gemini: (0, 0.3), other: (0.8, 0.9)))
        let gemini = snap.scoped(toAntigravityModel: "gemini-3.8-flash")
        await t.check("Gemini 모델로 보면 Gemini 창만 · 계정 전체 창으로", gemini.windows.count == 2
                        && gemini.windows.allSatisfy { $0.model == nil && $0.label.hasPrefix("Gemini") })
        await t.check("그 묶음의 5시간 창이 찼으면 한도 도달 · 초기화 시각을 안다",
                      gemini.status == .subscriptionCap && gemini.reachedAccountWideCap && gemini.capResetsAt() != nil)
        let other = snap.scoped(toAntigravityModel: "claude-sonnet-4-6")
        await t.check("Claude 모델로 보면 그 묶음은 여유", other.status == .ok && !other.reachedAccountWideCap
                        && other.windows.allSatisfy { $0.label.hasPrefix("Claude · GPT") })
        var claude = LimitSnapshot(provider: .claude)
        claude.windows = [LimitWindow(label: "현재 세션", utilization: 0.4)]
        await t.equal("Antigravity 가 아니면 그대로", claude.scoped(toAntigravityModel: "gemini-3.8-flash"), claude)
        let unknownGroup = snap.scoped(toAntigravityModel: nil)
        await t.check("모델을 모르면 앱 기본(Gemini)의 묶음", unknownGroup.windows.count == 2
                        && unknownGroup.windows.allSatisfy { $0.label.hasPrefix("Gemini") })
        let onlyOther = parse(#"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Claude and GPT models","buckets":[{"window":"5h","remaining_fraction":0.5}]}]}}}"#)
        await t.equal("그 묶음의 창이 없으면 그대로 (묶음 창 — 받는 쪽 사실은 정보 없음)",
                      onlyOther.scoped(toAntigravityModel: "gemini-3.8-flash"), onlyOther)
    }

    private static func presentation(_ t: TestKit) async {
        await t.group("Antigravity 한도: 칩 · 카드의 글")
        let snap = parse(response(gemini: (0.9, 0.7), other: (0.2, 0.5)))
        await t.equal("칩은 계정 전체 창이 없으면 가장 많이 쓴 창 (Claude · GPT 5시간 80%)",
                      LimitsPresentation.chipWindow(snap)?.label, "Claude · GPT 5시간")
        let state = LimitsPresentation.state(snap)
        await t.equal("칩 글", LimitsPresentation.chipText(state), "80%")
        let line = LimitsPresentation.line(name: "Antigravity", state: state, fetchedAt: nil)
        await t.equal("도움말 줄에 묶음과 창", line, "Antigravity · Claude · GPT 5시간 한도 80% 사용")
        var claude = LimitSnapshot(provider: .claude)
        claude.windows = [LimitWindow(label: "현재 세션", utilization: 0.1, model: nil),
                          LimitWindow(label: "이번 주 (Fable)", utilization: 0.9, model: "Fable")]
        await t.equal("계정 전체 창이 있으면 예전처럼 그것 (모델 한도가 더 높아도)",
                      LimitsPresentation.chipWindow(claude)?.label, "현재 세션")

        let now = Date()
        let raw = HandoffCardText.limitFact(provider: .gemini, limit: snap, now: now)
        await t.equal("묶음 그대로는 받는 쪽 사실이 없다 (계정 전체 창이 아니다)", raw?.text, "한도 정보 없음")
        let scoped = HandoffCardText.limitFact(provider: .gemini, limit: snap.scoped(toAntigravityModel: "gemini-3.8-flash"), now: now)
        await t.check("받는 모델의 묶음으로 보면 사용률 (Gemini 7일 30%)", (scoped?.text ?? "").hasPrefix("사용률 30%"), scoped?.text ?? "")
        let full = parse(response(gemini: (0, 0.5), other: (1, 1))).scoped(toAntigravityModel: nil)
        await t.check("받는 모델의 묶음이 찼으면 한도 도달",
                      (HandoffCardText.limitFact(provider: .gemini, limit: full, now: now)?.text ?? "").hasPrefix("한도 도달"))
    }

    /// 가짜 agy 로 실제 조회 길 — 인수 · 작업 폴더 · 실패.
    private static func fetching(_ t: TestKit) async {
        await t.group("Antigravity 한도: 조회 (가짜 agy)")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-agy-usage-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let log = root.appendingPathComponent("args.log")
            let body = root.appendingPathComponent("usage.json")
            try sample.write(to: body, atomically: true, encoding: .utf8)
            let agy = root.appendingPathComponent("agy")
            try """
            #!/bin/sh
            echo "$@" > '\(log.path)'
            pwd >> '\(log.path)'
            cat '\(body.path)'
            """.write(to: agy, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
            let snap = await LimitsFetcher.fetchAntigravity(path: agy.path, environment: ProcessInfo.processInfo.environment)
            await t.check("응답을 해석한다", snap.status == .ok && snap.windows.count == 4 && snap.fetchedAt != nil, snap.message ?? "")
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            await t.equal("인수: -p /usage --output-format json (모델을 부르지 않는 명령)", lines.first, "-p /usage --output-format json")
            let cwd = lines.count > 1 ? lines[1] : ""
            await t.check("프로젝트 폴더가 아닌 중립 폴더에서 돈다", !cwd.isEmpty && cwd != FileManager.default.currentDirectoryPath
                            && !cwd.hasPrefix(root.path), cwd)

            let failing = root.appendingPathComponent("agy-fail")
            try "#!/bin/sh\necho 'Error: not logged in' >&2\nexit 1\n".write(to: failing, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
            let failed = await LimitsFetcher.fetchAntigravity(path: failing.path, environment: ProcessInfo.processInfo.environment)
            await t.check("실패하면 까닭 · 원문 (0% 로 채우지 않는다)", failed.status == .authProblem && failed.windows.isEmpty
                            && (failed.message ?? "").contains("not logged in"), failed.message ?? "")
        } catch {
            await t.check("가짜 agy 준비", false, "\(error)")
        }
    }

    /// 허용한 프로젝트가 없으면 읽지 않는다 (`agy -p /usage` 도 Google 과 통신 — `agy models` 와 같은 원칙).
    private static func service(_ t: TestKit) async {
        await t.group("Antigravity 한도: 읽는 조건")
        let calls = UncheckedBox<[AgentScope]>([])
        let previous = LimitsService.fetchOverride
        let parsed = parse(sample)
        LimitsService.fetchOverride = { scope in
            calls.value.append(scope)
            return scope.provider == .gemini ? parsed : LimitSnapshot(provider: scope.provider, accountID: scope.accountID)
        }
        defer { LimitsService.fetchOverride = previous }
        let limits = LimitsService(environment: CLIEnvironment())
        await limits.refresh(.gemini, force: true)
        await t.check("꺼져 있으면 읽지 않는다", calls.value.isEmpty && limits.gemini.fetchedAt == nil)
        await limits.refreshAll(force: true)
        await t.check("새로고침(전부)에도 넣지 않는다", !calls.value.contains(.gemini))
        await t.check("메뉴바의 한도 목록에도 없다", !limits.allSnapshots.contains { $0.provider == .gemini })
        limits.antigravityEnabled = true
        calls.value = []
        await limits.refresh(.gemini, force: true)
        await t.check("켜면 읽는다", calls.value == [.gemini] && limits.gemini.windows.count == 4)
        calls.value = []
        await limits.refreshAll(force: true)
        await t.check("새로고침(전부)에 들어간다", calls.value.contains(.gemini))
        await t.check("메뉴바의 한도 목록에 들어간다", limits.allSnapshots.contains { $0.provider == .gemini })
        calls.value = []
        await limits.refresh(.gemini)
        await t.check("1분 안에는 다시 읽지 않는다", calls.value.isEmpty)
    }

    /// 앱 모델: 프로젝트에서 허용하면 켜지고 칩 · 팝오버에 줄이 생긴다, 모두 거두면 사라진다.
    private static func appModel(_ t: TestKit) async {
        await t.group("Antigravity 한도: 앱 모델")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-agy-limits-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = LimitsService.fetchOverride
        let parsed = parse(sample)
        LimitsService.fetchOverride = { scope in
            scope.provider == .gemini ? parsed : LimitSnapshot(provider: scope.provider, accountID: scope.accountID)
        }
        defer { LimitsService.fetchOverride = previous }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "p", path: root.path)
            try await store.upsertProject(project)
            let model = AppModel(store: store)
            model.cliStatus[.gemini] = CLIStatus(provider: .gemini, resolvedPath: "/fake/agy", executable: true)
            await t.check("허용한 프로젝트가 없으면 꺼짐 · 칩에 줄이 없다", !model.limits.antigravityEnabled
                            && !model.limitEntries.contains { $0.snapshot.provider == .gemini })
            model.setAntigravityAllowed(true, projectID: project.id)
            await t.check("프로젝트에서 허용하면 켜진다", model.limits.antigravityEnabled)
            await model.limits.refresh(.gemini, force: true)
            let entry = model.limitEntries.first { $0.snapshot.provider == .gemini }
            await t.check("칩 · 팝오버에 Antigravity 줄 (값이 있다)", entry?.name == "Antigravity" && entry?.state.hasValue == true)
            model.cliStatus[.gemini] = CLIStatus(provider: .gemini)
            await t.check("이 Mac 에서 agy 를 쓸 수 없으면 줄을 뺀다", !model.limitEntries.contains { $0.snapshot.provider == .gemini })
            model.cliStatus[.gemini] = CLIStatus(provider: .gemini, resolvedPath: "/fake/agy", executable: true)
            model.setAntigravityAllowed(false, projectID: project.id)
            await t.check("모두 거두면 꺼지고 줄도 없다", !model.limits.antigravityEnabled
                            && !model.limitEntries.contains { $0.snapshot.provider == .gemini })
            await t.check("자동 인계 · 이어 가기 순서에는 넣지 않는다 (v0.1 은 보이기만)",
                          !model.automaticHandoffTargetOrder.contains { $0.provider == .gemini })
        } catch {
            await t.check("임시 저장소 준비", false, "\(error)")
        }
    }
}
