import Foundation

/// 아주 얇은 테스트 러너. 앱의 실제 코드를 그대로 호출한다.
/// 일반 실행 경로를 테스트용 가짜 데이터로 대체하지 않는다.
actor TestKit {
    struct Result {
        var name: String
        var passed: Bool
        var detail: String
        var group: String
    }

    private(set) var results: [Result] = []
    private var currentGroup = "일반"

    func group(_ name: String) { currentGroup = name }

    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        results.append(Result(name: name, passed: condition, detail: detail, group: currentGroup))
        let mark = condition ? "  ok  " : " FAIL "
        print("[\(mark)] \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        fflush(stdout)
    }

    func equal<T: Equatable>(_ name: String, _ a: T, _ b: T) {
        check(name, a == b, a == b ? "\(a)" : "기대 \(b), 실제 \(a)")
    }

    func note(_ text: String) {
        print("       · \(text)")
        fflush(stdout)
    }

    func summary() -> Bool {
        let failed = results.filter { !$0.passed }
        print("\n================ 결과 ================")
        var groups: [String: (Int, Int)] = [:]
        for r in results {
            var g = groups[r.group] ?? (0, 0)
            g.0 += 1
            if r.passed { g.1 += 1 }
            groups[r.group] = g
        }
        for key in groups.keys.sorted() {
            let (total, passed) = groups[key]!
            let mark = passed == total ? "ok  " : "FAIL"
            let width = 36 - key.count
            let pad = String(repeating: " ", count: max(1, width))
            print("[\(mark)] \(key)\(pad)\(passed)/\(total)")
        }
        print("--------------------------------------")
        print("합계 \(results.count - failed.count)/\(results.count) 통과")
        if !failed.isEmpty {
            print("\n실패 항목:")
            for f in failed { print("  ✗ [\(f.group)] \(f.name) — \(f.detail)") }
        }
        return failed.isEmpty
    }
}

enum TestEnv {
    /// 오프라인 시험의 하네스: 한도는 정해 둔 값(`LimitsService.fetchOverride`), 실제 claude · codex · agy 는 찾지 않는다
    /// (`CLIEnvironment.harnessFallback` — 앱 모델의 부트스트랩 · 모델 목록 · 로그인 확인이 부르던 것). 가짜 CLI 는 시험마다 setOverrides 로.
    @MainActor
    static func offlineHarness(_ on: Bool) {
        if on {
            LimitsService.fetchOverride = { scope in offlineLimitSnapshot(scope) }
            let absent = NSTemporaryDirectory() + "ahc-offline-no-cli-\(ProcessInfo.processInfo.processIdentifier)"
            CLIEnvironment.harnessFallback = .init(claudePath: absent + "/claude", codexPath: absent + "/codex",
                                                   geminiPath: absent + "/agy")
            // 사용자의 실제 셸(`~/.zshrc`)을 띄우지 않는다 — 이 프로세스의 PATH 만 (셸 환경 읽기 자체는 가짜 셸로 따로 시험한다).
            let inherited = ProcessInfo.processInfo.environment["PATH"]
            CLIEnvironment.harnessShellEnvironment = { CLIEnvironment.ShellEnvironment(path: inherited, source: .interactive) }
            // 사람의 ~/.codex/config.toml (기본 모델 · 강도)을 읽지 않는다 — 시험이 고르지 않은 강도를 푸는 값이 이 Mac 에 따라 달라지지 않게.
            CodexConfigDefaults.readOverride = { _ in CodexConfigDefaults() }
        } else {
            LimitsService.fetchOverride = nil
            CLIEnvironment.harnessFallback = nil
            CLIEnvironment.harnessShellEnvironment = nil
            CodexConfigDefaults.readOverride = nil
        }
    }

    /// 오프라인 시험의 한도 — 여유 있음(사용률 10%, 방금 확인). Antigravity 는 정보 없음 (해석 · 묶음은 `AntigravityLimitsTests` 가 따로 본다).
    @MainActor
    static func offlineLimitSnapshot(_ scope: AgentScope) -> LimitSnapshot {
        guard scope.provider != .gemini else { return LimitSnapshot(provider: .gemini) }
        var snap = LimitSnapshot(provider: scope.provider, accountID: scope.accountID)
        snap.status = .ok
        snap.fetchedAt = Date()
        snap.windows = [LimitWindow(label: "5시간", utilization: 0.1, resetsAt: Date().addingTimeInterval(3 * 3600), spanMinutes: 300),
                        LimitWindow(label: "7일", utilization: 0.1, resetsAt: Date().addingTimeInterval(5 * 86400), spanMinutes: 10080)]
        return snap
    }

    /// 임시 테스트 프로젝트 폴더. 실제 CLI 통합 검증은 여기서만 수행한다.
    static func makeTempProject(_ name: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-inttest-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func resolveCLI() async -> (claude: String?, codex: String?, env: [String: String]) {
        let cli = CLIEnvironment()
        let claude = await cli.resolveExecutable(.claude)
        let codex = await cli.resolveExecutable(.codex)
        let env = await cli.childEnvironment()
        return (claude, codex, env)
    }
}

/// 스트림을 수집해 검증하기 쉬운 형태로 만든다.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [AgentEvent] = []
    private(set) var text = ""
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var questions: [UserQuestion] = []
    private(set) var notices: [String] = []
    private(set) var finished: AgentTurnResult?
    private(set) var sessionID: String?
    private(set) var limits: [LimitSnapshot] = []
    private(set) var toolNames: [String] = []
    private(set) var commands: [String] = []
    private(set) var fileChanges: [[String]] = []

    func ingest(_ e: AgentEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(e)
        switch e {
        case .sessionEstablished(let sid, _, _): sessionID = sid
        case .assistantDelta(let t): text += t
        case .assistantMessage(let t): text = t
        case .approvalRequested(let r): approvals.append(r)
        case .questionAsked(let q): questions.append(q)
        case .notice(let n): notices.append(n)
        case .rateLimits(let s): limits.append(s)
        case .toolStarted(_, let name, _): toolNames.append(name)
        case .commandExecution(_, let c, _, _, _, _): commands.append(c)
        case .fileChange(_, let paths, _, _): fileChanges.append(paths)
        case .finished(let r): finished = r
        default: break
        }
    }
}
