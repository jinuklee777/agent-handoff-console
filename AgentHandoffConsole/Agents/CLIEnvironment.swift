import Foundation

/// CLI 실행 파일 탐색과 자식 프로세스 환경 구성.
///
/// Finder 에서 실행한 `.app` 은 터미널과 환경이 다르다 (PATH 는 보통 /usr/bin:/bin:/usr/sbin:/sbin, `~/.zshrc` 의 변수는 없다).
/// 그래서 다음 순서로 실행 파일을 찾는다.
///   1) 사용자가 설정에서 지정한 경로 (`~` 를 푼다)
///   2) 셸이 보고하는 PATH — 대화형 로그인 셸(`$SHELL -ilc`, `~/.zshrc` 까지)에게 한 번 묻고, 안 되면 로그인 셸(`-lc`)
///      (**읽기만** 한다. 셸 설정을 수정하지 않는다 — `shellEnvironment()`)
///   3) 버전 관리자(nvm · fnm · mise · asdf · nodenv …)의 폴더 · 일반적인 설치 위치 목록
///   4) 상속받은 PATH
/// 자식 환경에는 셸이 알려 준 변수 가운데 허용 목록(`isForwardedShellVariable` — 프록시 · Bedrock 등)만 넣는다. 인증 변수
/// (`authVariableNames` — API 키 · 토큰)는 설정에서 켠 사람만 넘긴다 (`forwardsShellAuth`, onb-19).
/// 앱이 물려받은 환경은 `inheritedEnvironment` 로만 쓴다 — 에이전트 세션이 앱을 띄웠으면 그 세션의 변수를 뺀다 (`inheritable`).
actor CLIEnvironment {

    struct Override: Codable, Sendable {
        var claudePath: String?
        var codexPath: String?
        var geminiPath: String?
    }

    /// 셸에게 물어 얻은 환경 (onb-2 · onb-3). nvm · mise 의 PATH, API 키 · 프록시 · Bedrock 같은 변수는 대개 `~/.zshrc` 에 있다 —
    /// Finder 로 연 앱은 그것을 물려받지 않아, 터미널에서는 되는 CLI 를 찾지 못하거나 로그인이 안 된 것처럼 실패했다.
    struct ShellEnvironment: Equatable, Sendable {
        enum Source: String, Equatable, Sendable {
            /// 대화형 로그인 셸 (`$SHELL -ilc`) — `~/.zshrc` 까지 읽었다.
            case interactive
            /// 로그인 셸만 (`$SHELL -lc`) — 대화형이 실패 · 시간 초과였다. `~/.zprofile` 까지.
            case loginOnly
        }
        var path: String?
        /// 자식에게 넘길 변수만 (`isForwardedShellVariable`). 값은 메모리에만 둔다 — 저장 · 기록하지 않는다.
        var variables: [String: String] = [:]
        var source: Source

        init(path: String?, variables: [String: String] = [:], source: Source) {
            self.path = path
            self.variables = variables
            self.source = source
        }

        /// 셸의 변수 전부에서 PATH 와 넘길 변수만 고른다.
        init(all: [String: String], source: Source) {
            var path: String?
            if let raw = all["PATH"] {
                let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { path = trimmed }
            }
            var forwarded: [String: String] = [:]
            for (name, value) in all where CLIEnvironment.isForwardedShellVariable(name) { forwarded[name] = value }
            self.init(path: path, variables: forwarded, source: source)
        }
    }

    private var cachedShell: ShellEnvironment?
    /// 셸 환경 조회가 실패했는지. 실패를 기억해 호출마다 다시 기다리지 않는다.
    private var shellProbeFailed = false
    /// 캐시의 세대. `invalidateLoginPath()` 가 올린다 — 그 전에 시작한 조회의 결과는 버린다.
    private var shellGeneration = 0
    /// 진행 중인 조회 (한 번에 하나 — 동시에 부른 쪽들은 이것을 함께 기다린다).
    private var shellProbe: (generation: Int, task: Task<ShellEnvironment?, Never>)?
    /// 셸 환경을 읽는 함수. 기본은 `probeShellEnvironment` (검증 하네스는 `harnessShellEnvironment`) — 시험이 바꿔 끼운다
    /// (`setShellEnvironmentProber` · `setLoginPathProber`).
    private var shellProber: @Sendable () async -> ShellEnvironment? = {
        if let harness = CLIEnvironment.harnessShellEnvironment { return await harness() }
        return await CLIEnvironment.probeShellEnvironment()
    }
    /// 셸 하나가 응답하지 않아도 앱이 멈추지 않도록 두는 제한 (대화형 · 로그인 셸 각각).
    static let shellProbeTimeout: TimeInterval = 5
    private var overrides = Override()
    /// 셸 · 물려받은 환경의 인증 변수(`authVariableNames`)를 자식에게 넘기는가. **기본은 넘기지 않는다** (onb-19) — `claude -p` 는
    /// 환경의 `ANTHROPIC_API_KEY` 를 구독 로그인보다 먼저 써서, 다른 일로 `~/.zshrc` 에 키를 둔 구독 사용자의 모든 실행이 API 요금으로
    /// 청구됐다. 설정 > 에이전트에서 켠 사람만 넘긴다 (`AppModel.forwardShellAuth` → `setForwardsShellAuth`).
    private var forwardsShellAuth = false
    private var statusCache: [AgentProvider: CLIStatus] = [:]
    /// CLI 상태 캐시의 세대 — 경로를 바꾸거나(`setOverrides`) 셸을 다시 읽게 하면(`invalidateLoginPath`) 올린다. 그 전에 시작한 확인이
    /// 늦게 끝나도 결과를 캐시에 넣지 않는다 (지운 캐시를 옛 경로 · 옛 PATH 의 결과로 다시 채우지 않게, set-n7).
    private var statusGeneration = 0
    /// 버전 관리자 폴더 (`versionManagerDirectories`) — 셸 캐시와 함께 버린다.
    private var cachedManagerDirectories: [String]?
    /// 지정한 실행 파일 경로 → 앞에 둘 PATH 폴더 (`#!/usr/bin/env node` 스크립트의 폴더, 아니면 ""). 경로 · 셸 캐시와 함께 버린다.
    private var scriptDirectoryCache: [String: String] = [:]

    /// 검증 하네스용: 설정의 경로(`setOverrides`)가 비어 있는 제공자에 대신 쓸 경로. `inttest offline` 이 없는 경로를 넣어
    /// 오프라인 시험이 실제 claude · codex · agy 를 찾거나 띄우지 않게 한다 (앱 모델의 부트스트랩 · 모델 목록 · 로그인 확인).
    /// 앱은 넣지 않는다. 시험이 자기 가짜 CLI 를 `setOverrides` 로 주면 그것이 먼저다.
    nonisolated(unsafe) static var harnessFallback: Override?
    /// 검증 하네스용: 사용자의 실제 셸(`~/.zshrc`)을 띄우지 않고 이것으로 셸 환경을 읽는다 (`inttest offline` — 앱 모델마다 대화형
    /// 셸이 뜨면 느리고 시험이 사용자 설정에 따라 달라진다). 앱은 넣지 않는다. 시험이 `setShellEnvironmentProber` 로 주면 그것이 먼저다.
    nonisolated(unsafe) static var harnessShellEnvironment: (@Sendable () async -> ShellEnvironment?)?

    static let commonDirectories: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.deno/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.claude/local",
            "\(home)/.codex/bin",
            "/usr/bin",
            "/bin",
        ]
    }()

    func setOverrides(_ o: Override) {
        overrides = o
        statusGeneration += 1
        statusCache.removeAll()
        scriptDirectoryCache.removeAll()
    }

    func currentOverrides() -> Override { overrides }

    func setForwardsShellAuth(_ on: Bool) { forwardsShellAuth = on }

    /// 셸(또는 앱이 물려받은 환경)에 값이 있는 인증 변수의 이름 — 넘기는지와 상관없이. 값은 돌려주지 않는다.
    /// 점검표 · 설정이 "셸에 API 키가 있지만 넘기지 않습니다" 를 말할 때 쓴다.
    func shellAuthVariables() async -> [String] {
        let shell = await shellEnvironment()?.variables ?? [:]
        let inherited = Self.inheritedEnvironment
        return Self.authVariableNames.filter { name in
            let value = shell[name] ?? inherited[name]
            return !(value ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// 셸에게 물어 얻은 환경 (캐시). 실패해도 앱은 동작해야 한다 — 실패는 기억해 호출마다 다시 기다리지 않는다.
    ///
    /// **한 번에 하나:** 진행 중인 조회가 있으면 새로 띄우지 않고 그것을 함께 기다린다 (시작 때 세 CLI 상태 확인이 동시에 부른다).
    /// **세대:** `invalidateLoginPath()`(점검표의 "다시 확인" — 사람이 셸 설정을 고쳤을 수 있다) 뒤에는 그 전 세대의 결과를
    /// 캐시에 넣지 않고, 기다리던 쪽은 새 세대의 조회를 다시 기다린다.
    func shellEnvironment() async -> ShellEnvironment? {
        while true {
            if let cachedShell { return cachedShell }
            if shellProbeFailed { return nil }
            let generation = shellGeneration
            let task: Task<ShellEnvironment?, Never>
            if let probe = shellProbe, probe.generation == generation {
                task = probe.task
            } else {
                let prober = shellProber
                task = Task.detached(priority: .userInitiated) { await prober() }
                shellProbe = (generation, task)
            }
            let result = await task.value
            // 기다리는 사이 세대가 바뀌었으면 이 결과는 버리고 새 세대로 다시 (사람이 고친 설정을 옛 값이 덮지 않게).
            guard generation == shellGeneration else { continue }
            if shellProbe?.generation == generation { shellProbe = nil }
            if let result {
                cachedShell = result
            } else {
                shellProbeFailed = true
            }
            return result
        }
    }

    /// 셸이 알려 준 PATH (캐시 — `shellEnvironment()`). 셸을 읽지 못했으면 nil.
    func loginShellPath() async -> String? {
        await shellEnvironment()?.path
    }

    /// 셸 환경 캐시를 버린다 — 세대를 올리고 캐시 · 실패 표시 · CLI 상태 캐시 · 버전 관리자 폴더를 비운다. 다음 조회가 셸을 다시 읽는다.
    /// (이름은 PATH 만 읽던 때의 것 — 점검표의 "다시 확인" 이 부른다.)
    func invalidateLoginPath() {
        shellGeneration += 1
        cachedShell = nil
        shellProbeFailed = false
        shellProbe = nil
        statusGeneration += 1
        statusCache.removeAll()
        cachedManagerDirectories = nil
        scriptDirectoryCache.removeAll()
    }

    #if DEBUG
    /// 검증 하네스용: 셸 환경 조회를 바꿔 끼운다 (세는 · 늦는 가짜). 캐시도 비운다.
    func setShellEnvironmentProber(_ prober: @escaping @Sendable () async -> ShellEnvironment?) {
        shellProber = prober
        invalidateLoginPath()
    }

    /// 검증 하네스용: PATH 만 돌려주는 가짜 조회 (변수 없음 · 로그인 셸). nil 이면 실패.
    func setLoginPathProber(_ prober: @escaping @Sendable () async -> String?) {
        setShellEnvironmentProber { await prober().map { ShellEnvironment(path: $0, source: .loginOnly) } }
    }
    #endif

    // MARK: 셸 환경 읽기

    /// 셸에게 환경을 묻는다 (한 번): 대화형 로그인 셸(`-ilc`, `~/.zshrc` 까지) → 실패 · 시간 초과면 로그인 셸(`-lc`). 둘 다 안 되면 nil.
    ///
    /// - 셸은 **새 세션에서** 띄운다(제어 터미널이 없다) — 대화형 셸이 터미널을 잡으려다 SIGTTOU 로 멈추거나 입력을 빼앗지 않게
    ///   (`spawnReadingStdout`). stdin · stderr 는 /dev/null.
    /// - 값은 앞뒤 표식 사이의 `/usr/bin/env -0` 만 읽는다 — 셸 설정이 찍는 인사말 · 프롬프트 잡음과 섞이지 않고, 줄바꿈이 든 값도
    ///   깨지지 않는다. 표식은 조회마다 새로 만든다.
    /// - 셸마다 **시간 제한**(`shellProbeTimeout`)을 두고, 넘기면 그 세션의 프로세스를 모두 끝낸다. 앱은 계속 동작해야 한다.
    /// - 셸 설정은 고치지 않는다. 셸에는 `AHC_RESOLVING_ENVIRONMENT=1`(셸 설정이 이 조회를 알아볼 수 있게)과 oh-my-zsh 의 업데이트
    ///   물음을 끄는 `DISABLE_AUTO_UPDATE=true` 만 더한다.
    static func probeShellEnvironment(shell: String? = nil, timeout: TimeInterval = shellProbeTimeout) async -> ShellEnvironment? {
        let fallbackShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let executable: String = shell ?? fallbackShell
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let attempts: [(flags: String, source: ShellEnvironment.Source)] = [("-ilc", .interactive), ("-lc", .loginOnly)]
        for attempt in attempts {
            if let all = await readEnvironment(shell: executable, flags: attempt.flags, timeout: timeout) {
                return ShellEnvironment(all: all, source: attempt.source)
            }
        }
        return nil
    }

    /// 셸 하나(`flags` — `-ilc` · `-lc`)로 환경 변수 전부를 읽는다. 표식을 못 찾았거나 시간이 넘었으면 nil.
    private static func readEnvironment(shell: String, flags: String, timeout: TimeInterval) async -> [String: String]? {
        let tag: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let begin: String = "__AHC_ENV_BEGIN_\(tag)__"
        let end: String = "__AHC_ENV_END_\(tag)__"
        // 절대 경로로 부른다 — 셸 설정의 별칭 · 함수(`printf` · `env`)를 비켜 간다. fish 에서도 같은 글로 돈다.
        let script: String = "/usr/bin/printf '%s' '\(begin)'; /usr/bin/env -0; /usr/bin/printf '%s' '\(end)'"
        var variables: [String: String] = inheritedEnvironment
        variables["AHC_RESOLVING_ENVIRONMENT"] = "1"
        variables["DISABLE_AUTO_UPDATE"] = "true"
        let environment: [String: String] = variables
        let directory: String = neutralWorkingDirectory().path
        let marker = Data(end.utf8)
        let captured: (output: Data, timedOut: Bool)? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = spawnReadingStdout(executable: shell, arguments: [flags, script], environment: environment,
                                                workingDirectory: directory, until: marker, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
        guard let captured, !captured.timedOut else { return nil }
        return parseEnvironmentDump(captured.output, begin: begin, end: end)
    }

    /// 표식 사이의 `env -0` 출력(NUL 로 나뉜 `이름=값`)을 푼다 (순수). 표식이 없거나 변수가 하나도 없으면 nil.
    static func parseEnvironmentDump(_ output: Data, begin: String, end: String) -> [String: String]? {
        guard let start = output.range(of: Data(begin.utf8)),
              let stop = output.range(of: Data(end.utf8), in: start.upperBound..<output.endIndex) else { return nil }
        var all: [String: String] = [:]
        for entry in output[start.upperBound..<stop.lowerBound].split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8),
                  let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            all[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return all.isEmpty ? nil : all
    }

    /// 자식(에이전트 CLI · git · agy)에게 넘길 셸 변수인가 — 허용 목록만. 셸의 모든 변수를 넘기지 않는다.
    /// API 키 · 엔드포인트(Anthropic · OpenAI · Google/Gemini), Claude Code · Codex 설정, Bedrock(AWS) · Vertex(Google · `CLOUD_ML_REGION`),
    /// 프록시 · 사내 인증서. `CODEX_HOME` 은 넣지 않는다 — 계정(= 홈)은 앱이 정한다 (`childEnvironment(codexHome:)`).
    /// 인증 변수(`authVariableNames`)도 여기서는 고르지만, 실제로 넘기는지는 `childEnvironment` 가 설정(`forwardsShellAuth`)으로 정한다.
    static func isForwardedShellVariable(_ name: String) -> Bool {
        if name == "CODEX_HOME" { return false }
        if forwardedPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        if forwardedNames.contains(name) { return true }
        return name.hasSuffix("_PROXY") || name.hasSuffix("_proxy")
    }

    /// Claude Code 가 OAuth 로그인 없이 쓸 수 있는 인증이 환경에 있는가 — API 키 · 토큰, 또는 Bedrock · Vertex 사용 (순수).
    /// 이때 `claude auth status` 의 "로그인 안 됨" 은 쓸 수 없다는 뜻이 아니다 (onb-3).
    static func usesClaudeAlternativeAuth(_ environment: [String: String]) -> Bool {
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] as [String] {
            if let value = environment[name], !value.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        for name in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"] as [String] {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces).lowercased() else { continue }
            if !value.isEmpty && value != "0" && value != "false" { return true }
        }
        return false
    }

    /// 자식(claude)이 받을 환경에 로그인 대신 쓸 인증이 있는가 (셸에서 넘긴 변수 포함).
    func claudeAlternativeAuth() async -> Bool {
        Self.usesClaudeAlternativeAuth(await childEnvironment())
    }

    /// 구독 로그인 대신 API 요금으로 청구되게 하는 인증 변수 — 설정에서 켠 사람만 넘긴다 (onb-19). 프록시 · 엔드포인트 · Bedrock · Vertex
    /// 같은 나머지 변수는 늘 넘긴다 (그것을 쓰는 사람은 일부러 둔 것이다).
    static let authVariableNames: [String] = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_CLOUD_API_KEY",
    ]

    /// 인증 변수를 넘기지 않을 때 자식 환경에서 뺀다 (순수) — 셸에서 온 것 · 앱이 물려받은 것 모두.
    static func withholdingAuth(_ environment: [String: String], forwards: Bool) -> [String: String] {
        guard !forwards else { return environment }
        var env = environment
        for name in authVariableNames { env.removeValue(forKey: name) }
        return env
    }

    private static let forwardedPrefixes: [String] = ["ANTHROPIC_", "CLAUDE_CODE_", "OPENAI_", "CODEX_", "AWS_", "GOOGLE_", "GEMINI_"]
    private static let forwardedNames: Set<String> = ["CLAUDE_CONFIG_DIR", "NO_PROXY", "no_proxy", "NODE_EXTRA_CA_CERTS",
                                                      "SSL_CERT_FILE", "CLOUD_ML_REGION"]

    // MARK: 물려받은 환경

    /// 앱을 띄운 쪽이 에이전트 세션(Claude Code · Codex 가 도구로 돌린 셸)인가 — 그 세션이 자식에게 넣는 표시 변수로 안다 (순수).
    /// 에이전트가 `open` · `scripts/install-app.sh` 로 앱을 열면 앱이 그 세션의 환경(세션 ID · 메시지 토큰 · 엔드포인트 ·
    /// `CLAUDE_CODE_ENTRYPOINT=claude-desktop` …)을 통째로 물려받았고, 그대로 넘기자 앱이 띄운 `claude -p` 가 그 세션의 일부처럼
    /// 기록됐다 (2026-10-07 실측 — 앱이 연 세션 기록의 entrypoint 가 claude-desktop).
    static let agentSessionMarkers: [String] = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                                                "CODEX_SANDBOX", "CODEX_THREAD_ID"]

    static func launchedFromAgentSession(_ environment: [String: String]) -> Bool {
        agentSessionMarkers.contains { !(environment[$0] ?? "").isEmpty }
    }

    /// 에이전트 세션 안에서 띄워졌을 때 물려받은 환경에서 남기는 것 — 로그인 세션의 기본 변수(+ `LC_*`)와 앱 자신의 `AHC_*`
    /// (검증 · 화면 확인용 설정). 나머지는 사용자의 환경이 아니라 그 세션의 것이다.
    static let sessionBaseNames: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "SSH_AUTH_SOCK",
                                                "LANG", "__CF_USER_TEXT_ENCODING"]

    /// 자식(셸 조회 · 에이전트 CLI · git · 터미널 탭의 셸)에게 물려줄 앱의 환경 (순수). 에이전트 세션 안에서 띄워졌으면 기본 변수만,
    /// 아니면 그대로 — Finder · Dock 으로 연 앱의 환경은 launchd 가 준 것과 사람이 `launchctl setenv` 로 둔 값이다.
    /// 사용자가 셸에 둔 값(PATH · API 키 · 프록시 · Bedrock …)은 어느 쪽이든 셸에게 따로 묻는다 (`shellEnvironment`).
    static func inheritable(_ environment: [String: String]) -> [String: String] {
        guard launchedFromAgentSession(environment) else { return environment }
        return environment.filter { name, _ in
            sessionBaseNames.contains(name) || name.hasPrefix("LC_") || name.hasPrefix("AHC_")
        }
    }

    /// 앱이 물려받은 환경 가운데 자식에게 물려줄 것 (`inheritable`).
    static var inheritedEnvironment: [String: String] { inheritable(ProcessInfo.processInfo.environment) }

    /// `executable` 을 새 세션에서 띄워(`POSIX_SPAWN_SETSID` — 제어 터미널이 없다) stdout 을 `marker` 가 나올 때까지 · 끝날 때까지 ·
    /// 시간 제한까지 읽는다 (막히는 함수 — 협력 스레드 밖에서 부른다). stdin · stderr 는 /dev/null, 다른 열린 파일은 물려주지 않는다.
    /// 시간이 넘었거나 다 읽은 뒤에도 셸이 끝나지 않으면 그 세션의 프로세스 그룹을 모두 끝내고 거둔다 (좀비 · 남는 셸 없음).
    /// `Process` 는 새 세션을 만들 수 없어 쓰지 않는다. 띄우지 못했으면 nil.
    static func spawnReadingStdout(executable: String, arguments: [String], environment: [String: String],
                                   workingDirectory: String, until marker: Data, timeout: TimeInterval,
                                   limit: Int = 8 << 20) -> (output: Data, timedOut: Bool)? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let readEnd = fds[0], writeEnd = fds[1]
        // 다른 스레드가 동시에 띄우는 자식이 이 파이프를 물려받지 않게 (물려받으면 EOF 가 오지 않는다).
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var flags: Int32 = POSIX_SPAWN_SETSID
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT
        flags |= POSIX_SPAWN_SETSIGMASK
        flags |= POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable)]
        for argument in arguments { argv.append(strdup(argument)) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = []
        for (name, value) in environment { envp.append(strdup(name + "=" + value)) }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            return nil
        }

        var output = Data()
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining: TimeInterval = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let capped: Double = remaining < 1.0 ? remaining : 1.0
            let waitMilliseconds: Int32 = Int32(capped * 1000.0) + 1
            let ready: Int32 = poll(&descriptor, 1, waitMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let count: Int = read(readEnd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if count == 0 { break }   // EOF — 셸이 끝났다
            let searchFrom: Int = max(0, output.count - marker.count)
            output.append(contentsOf: buffer[0..<count])
            if output.range(of: marker, in: searchFrom..<output.count) != nil { break }
            if output.count > limit { break }
        }
        close(readEnd)

        // 거두기: 다 읽었으면 셸은 곧 끝난다 (`exit` · `.zlogout` 만 남았다) — 잠깐 기다린다. 시간이 넘었거나 끝나지 않으면
        // 새 세션의 프로세스 그룹(셸이 띄운 자식 포함)을 끝낸다.
        var status: Int32 = 0
        var reaped = false
        if !timedOut {
            for _ in 0..<20 {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid || (waited < 0 && errno != EINTR) { reaped = true; break }
                usleep(50_000)
            }
        }
        if !reaped {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        return (output, timedOut)
    }

    // MARK: PATH

    /// 자식 프로세스에 넘길 환경. CLI 가 node/git/rg 등을 찾을 수 있어야 하고, 터미널에서 쓰던 프록시 · Bedrock 설정이 넘어가야 한다.
    /// API 키 · 토큰(`authVariableNames`)은 설정에서 켰을 때만 (`withholdingAuth`).
    ///
    /// `codexHome` 을 주면 그 프로세스만 해당 `CODEX_HOME` 을 쓴다 (셸의 값보다 앞선다).
    /// 계정 전환은 이 환경 변수 하나로 끝나며, 앱은 `~/.codex` 를 비롯한
    /// 어떤 홈의 파일도 옮기거나 고쳐 쓰지 않는다.
    func childEnvironment(codexHome: String? = nil) async -> [String: String] {
        var env = Self.inheritedEnvironment
        let inherited = env["PATH"]
        let shell = await shellEnvironment()
        // 셸의 값이 앱이 물려받은 값보다 먼저다 (터미널에서 쓰던 값). 허용 목록의 변수만 (`isForwardedShellVariable`).
        for (name, value) in shell?.variables ?? [:] { env[name] = value }
        env["PATH"] = Self.composePath(pinned: scriptDirectories(), shell: shell?.path,
                                       managers: managerDirectories(), common: Self.commonDirectories,
                                       inherited: inherited).joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        // CLI 가 대화형 TUI 로 전환하지 않도록.
        env["TERM"] = env["TERM"] ?? "dumb"
        if let codexHome, !codexHome.isEmpty {
            env["CODEX_HOME"] = (codexHome as NSString).expandingTildeInPath
        }
        return Self.withholdingAuth(env, forwards: forwardsShellAuth)
    }

    /// PATH 의 순서 (순수 — 겹친 폴더는 앞의 것만): 지정한 스크립트의 폴더 → 셸의 PATH → 버전 관리자 폴더 → 일반 설치 위치 → 물려받은 PATH.
    static func composePath(pinned: [String], shell: String?, managers: [String], common: [String], inherited: String?) -> [String] {
        var all: [String] = pinned
        all += pathEntries(shell)
        all += managers
        all += common
        all += pathEntries(inherited)
        var seen = Set<String>()
        var result: [String] = []
        for directory in all where !directory.isEmpty && seen.insert(directory).inserted {
            result.append(directory)
        }
        return result
    }

    private static func pathEntries(_ path: String?) -> [String] {
        guard let path else { return [] }
        return path.split(separator: ":").map { String($0) }
    }

    private func searchDirectories() async -> [String] {
        Self.composePath(pinned: [], shell: await shellEnvironment()?.path, managers: managerDirectories(),
                         common: Self.commonDirectories, inherited: Self.inheritedEnvironment["PATH"])
    }

    private func managerDirectories() -> [String] {
        if let cachedManagerDirectories { return cachedManagerDirectories }
        let found = Self.versionManagerDirectories()
        cachedManagerDirectories = found
        return found
    }

    /// Node 버전 관리자로 설치한 CLI 의 폴더 — 셸을 읽지 못했을 때도 찾게 (있는 폴더만). nvm 은 가장 새 버전 하나,
    /// fnm 은 기본 별칭, mise · asdf · nodenv 는 shims, pnpm · yarn 의 전역 설치 폴더. volta 는 `commonDirectories` 에 있다.
    static func versionManagerDirectories(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        var candidates: [String] = []
        let nvmVersions: String = home + "/.nvm/versions/node"
        let installed: [String] = (try? fm.contentsOfDirectory(atPath: nvmVersions)) ?? []
        if let newest = newestVersionDirectory(in: installed) {
            candidates.append(nvmVersions + "/" + newest + "/bin")
        }
        for suffix in managerSuffixes { candidates.append(home + suffix) }
        return candidates.filter { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// 홈 아래의 버전 관리자 폴더 (nvm 은 따로 — 버전 폴더를 고른다).
    private static let managerSuffixes: [String] = [
        "/.local/share/fnm/aliases/default/bin",
        "/Library/Application Support/fnm/aliases/default/bin",
        "/.fnm/aliases/default/bin",
        "/.local/share/mise/shims",
        "/.asdf/shims",
        "/.nodenv/shims",
        "/Library/pnpm",
        "/.yarn/bin",
    ]

    /// `v22.11.0` 같은 폴더 이름 가운데 가장 새 버전 (순수). 버전 꼴이 아닌 이름은 뺀다.
    static func newestVersionDirectory(in names: [String]) -> String? {
        var best: (name: String, version: [Int])?
        for name in names {
            guard let version = versionNumbers(name) else { continue }
            if let current = best, !current.version.lexicographicallyPrecedes(version) { continue }
            best = (name, version)
        }
        return best?.name
    }

    /// "v22.11.0" → [22, 11, 0]. 숫자 마디가 아니면 nil.
    private static func versionNumbers(_ name: String) -> [Int]? {
        let digits: String = name.hasPrefix("v") ? String(name.dropFirst()) : name
        var numbers: [Int] = []
        for part in digits.split(separator: ".") {
            guard let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers.isEmpty ? nil : numbers
    }

    /// 지정한 실행 파일 가운데 `#!/usr/bin/env node` 같은 스크립트의 폴더 — PATH 맨 앞에 둔다. nvm 의 `…/bin/claude` 를 지정하면
    /// 그 옆의 `node` 를 찾게 된다 (앱의 PATH 에 node 가 없으면 "env: node: No such file or directory" 로 실패했다, onb-2).
    /// 심볼릭 링크는 풀지 않는다 — 링크가 있는 폴더(`…/bin`)에 node 가 있다.
    private func scriptDirectories() -> [String] {
        var directories: [String] = []
        for provider in AgentProvider.allCases {
            guard let path = overridePath(provider) else { continue }
            let directory: String
            if let cached = scriptDirectoryCache[path] {
                directory = cached
            } else {
                directory = Self.usesEnvInterpreter(atPath: path) ? (path as NSString).deletingLastPathComponent : ""
                scriptDirectoryCache[path] = directory
            }
            if !directory.isEmpty, !directories.contains(directory) { directories.append(directory) }
        }
        return directories
    }

    /// 파일의 첫 줄이 `#!/usr/bin/env …`(해석기를 PATH 에서 찾는 스크립트)인가.
    static func usesEnvInterpreter(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256), head.starts(with: Data("#!".utf8)) else { return false }
        let line = String(decoding: head.prefix { $0 != 10 }, as: UTF8.self)
        return line.range(of: #"^#!\s*\S*/env(\s|$)"#, options: .regularExpression) != nil
    }

    /// 설정에 적은 경로 — 앞뒤 공백을 떼고 `~` 를 푼다. 비었으면 nil.
    static func expandedOverride(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    private func overridePath(_ provider: AgentProvider) -> String? {
        let fallback = Self.harnessFallback
        let raw: String?
        switch provider {
        case .claude: raw = overrides.claudePath ?? fallback?.claudePath
        case .codex: raw = overrides.codexPath ?? fallback?.codexPath
        case .gemini: raw = overrides.geminiPath ?? fallback?.geminiPath
        }
        return Self.expandedOverride(raw)
    }

    private func binaryName(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "agy"
        }
    }

    /// 실행 파일 경로를 찾는다. 심볼릭 링크는 그대로 두고 실행 가능 여부만 확인한다. 지정한 경로는 `~` 를 푼다.
    func resolveExecutable(_ provider: AgentProvider) async -> String? {
        if let custom = overridePath(provider) {
            if FileManager.default.isExecutableFile(atPath: custom) { return custom }
            return nil   // 사용자가 지정했는데 실행 불가면 조용히 다른 곳으로 넘어가지 않는다.
        }
        let name = binaryName(provider)
        for dir in await searchDirectories() {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// 에이전트 제공자와 무관한 보조 CLI(예: `agy`)를 같은 PATH 규칙으로 찾는다.
    /// override 를 명시했는데 실행할 수 없으면 다른 경로로 조용히 대체하지 않는다.
    func resolveExecutable(named name: String, override: String? = nil) async -> String? {
        if let custom = Self.expandedOverride(override) {
            return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil
        }
        if name == binaryName(.gemini), let fallback = Self.harnessFallback?.geminiPath {
            return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
        }
        for dir in await searchDirectories() {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Claude Code 로그인 여부 (`claude auth status --json` 의 `loggedIn`, 로컬 확인이라 토큰을 쓰지 않는다).
    /// 확인하지 못하면 nil — 로그인됐다고 가정하지 않는다.
    /// 실측(2026-09-12, 2.1.233): OAuth 가 만료되면 `loggedIn: false`. 이때 턴을 보내면 CLI 가
    /// "Failed to authenticate" 를 응답처럼 내보낸다.
    func claudeLoggedIn() async -> Bool? {
        guard let path = await resolveExecutable(.claude) else { return nil }
        let env = await childEnvironment()
        guard case .success(let output) = await Self.captureOutput(
            executable: path, arguments: ["auth", "status", "--json"],
            environment: env, timeout: 20) else { return nil }
        return Self.parseClaudeAuthStatus(output)
    }

    static func parseClaudeAuthStatus(_ output: String) -> Bool? {
        JSONUtil.object(output.trimmingCharacters(in: .whitespacesAndNewlines))?["loggedIn"] as? Bool
    }

    /// 실제 경로 + 버전 + 실행 가능 여부를 확인한다. 결과에는 그때 설정에서 지정해 둔 경로(`CLIStatus.pinnedPath`)를 적는다 —
    /// 확인하는 사이 경로를 바꿨거나 셸을 다시 읽게 했으면 결과를 캐시에 넣지 않고(`statusGeneration`), 앱도 화면에 쓰지 않는다
    /// (`isCurrent`, set-n7: 늦게 끝난 옛 경로의 확인이 새 경로의 "준비됨" 을 "찾지 못함" 으로 덮었다).
    func checkStatus(_ provider: AgentProvider, force: Bool = false) async -> CLIStatus {
        let pinned = overridePath(provider)
        if !force, let cached = statusCache[provider], cached.pinnedPath == pinned,
           let checkedAt = cached.checkedAt, Date().timeIntervalSince(checkedAt) < 300 {
            return cached
        }
        let generation = statusGeneration

        var status = CLIStatus(provider: provider)
        status.checkedAt = Date()
        status.pinnedPath = pinned

        guard let path = await resolveExecutable(provider) else {
            status.error = pinned.map {
                "설정에서 지정한 경로를 실행할 수 없습니다: \($0)"
            } ?? "\(binaryName(provider)) 실행 파일을 찾지 못했습니다. 설정에서 경로를 지정하세요."
            if generation == statusGeneration { statusCache[provider] = status }
            return status
        }
        status.resolvedPath = path
        status.executable = true

        let env = await childEnvironment()
        let captured = await Self.captureProcess(executable: path, arguments: ["--version"], environment: env, timeout: 20)
        // 종료 코드가 0 이 아니어도 stdout 이 있으면 버전으로 읽는다 (`captureOutput` 과 같은 규칙).
        if captured.note == nil, let exit = captured.exitStatus, exit == 0 || !captured.stdout.isEmpty {
            status.version = captured.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init)
        } else if Self.cannotRun(exitStatus: captured.exitStatus, note: captured.note, output: captured.combinedOutput) {
            // 찾았지만 돌지 않는다 (`#!/usr/bin/env node` 인데 node 를 못 찾음 · 깨진 설치 등) — 쓸 수 없음으로 둔다. 그대로 보내면
            // 같은 오류로 실패한다 (onb-2). 점검표 · 보내기 거절이 이 글을 그대로 보인다 (`AppModel.agentReadiness` → 실행할 수 없음).
            status.executable = false
            status.error = Self.runFailureMessage(binary: binaryName(provider), output: captured.combinedOutput)
        } else {
            // `--version` 을 모르거나 느린 CLI 일 수 있다 — 쓸 수 있음으로 두고 까닭만 남긴다 (예전 동작).
            status.error = "버전 확인 실패: \(captured.combinedOutput)"
        }

        if generation == statusGeneration { statusCache[provider] = status }
        return status
    }

    /// 이 결과가 지금 설정의 경로로 확인한 것인가 — 확인하는 사이 그 제공자의 경로를 바꿨으면 false (그 결과는 옛 경로의 것이다).
    /// 앱은 false 인 결과를 `cliStatus` 에 쓰지 않는다 — 바꾼 경로의 다시 확인이 뒤에 쓴다 (`AppModel.refreshAgentFacts`, set-n7).
    func isCurrent(_ status: CLIStatus) -> Bool {
        status.pinnedPath == overridePath(status.provider)
    }

    /// `--version` 실패가 "아예 돌지 않음" 인가 (순수): 띄우지 못함(시간 초과는 빼고), 종료 코드 126 · 127(실행 권한 · 해석기나 명령을
    /// 찾지 못함), 또는 해석기를 못 찾았다는 말. 그 밖의 실패(모르는 옵션 등)는 돌기는 하는 것이다.
    static func cannotRun(exitStatus: Int32?, note: String?, output: String) -> Bool {
        if let note { return !note.hasPrefix("시간 초과") }
        if exitStatus == 126 || exitStatus == 127 { return true }
        let lowered: String = output.lowercased()
        for sign in ["bad interpreter", "env: node", "no such file or directory", "command not found"] as [String] {
            if lowered.contains(sign) { return true }
        }
        return false
    }

    /// `--version` 이 실패했을 때의 글: 무엇이 안 됐는지 + CLI 가 남긴 말(앞 세 줄 · 300자까지).
    static func runFailureMessage(binary: String, output: String) -> String {
        var lines: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed: String = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        var detail: String = lines.prefix(3).joined(separator: "\n")
        if detail.count > 300 { detail = String(detail.prefix(300)) + "…" }
        if detail.isEmpty { detail = "출력 없음" }
        return "\(binary) 를 실행하지 못했습니다 (--version): \(detail)"
    }

    enum CaptureResult {
        case success(String)
        case failure(String)
    }

    /// 명령 하나의 stdout · stderr · 종료 코드를 따로 담는다.
    struct ProcessCapture: Sendable {
        /// nil 이면 실행하지 못했거나 시간 초과로 끊었다 (`note` 에 이유).
        var exitStatus: Int32?
        var stdout = ""
        var stderr = ""
        var note: String?

        /// 종료 코드 0 으로 끝났을 때만 성공이다.
        var succeeded: Bool { note == nil && exitStatus == 0 }

        /// 기록·화면용 출력 (stdout 다음 stderr). 둘 다 비었으면 실패 이유를 대신 쓴다.
        var combinedOutput: String {
            let parts = [stdout, stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
            if let note { return note }
            if let exitStatus, exitStatus != 0 { return "종료 코드 \(exitStatus)" }
            return ""
        }
    }

    /// 작업 폴더가 없는 보조 명령(`claude -p /usage` · `/model` · `auth status` · `--version`, 한도 · 모델 조회용
    /// `codex app-server`, `agy`, 로그인 셸 등)이 도는 빈 폴더 (사용자 임시 폴더 안 — 없으면 만든다).
    /// 2026-09-24 실측: 지정하지 않으면 앱의 작업 폴더인 `/` 를 물려받고, Claude CLI 가 거기서 디스크를 훑어 음악 보관함 · 사진
    /// 보관함 · 다운로드 · 네트워크 볼륨에 닿는다. macOS 는 자식의 접근을 앱에 묻기 때문에, 앱을 켤 때마다 앱 이름으로 권한 창이 떴다
    /// (tccd 기록의 접근 주체가 `~/.local/share/claude/versions/2.1.270`). 기록 가져오기는 이 폴더(`/var/folders/…`)를 고르지 않는다.
    static func neutralWorkingDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHandoffConsole-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 대화가 필요 없는 `claude -p` 보조 명령(`/usage` · `/model`)을 부른다. 부를 때마다 대화 파일이
    /// `~/.claude/projects/<작업 폴더>/` 에 남지 않게 `--no-session-persistence` 를 붙이고 (2026-09-24: `/` 폴더에 55개가 쌓여 있었다),
    /// 이 옵션을 모르는 옛 CLI 가 거절하면 빼고 다시 부른다. `model` 은 이 호출에만 쓰는 `--model` (설정은 바뀌지 않는다).
    static func captureClaudePrint(path: String, command: String, model: String? = nil,
                                   environment: [String: String], timeout: TimeInterval) async -> CaptureResult {
        let base = ["-p", command, "--output-format", "json"] + (model.map { ["--model", $0] } ?? [])
        let result = await captureOutput(executable: path, arguments: base + [claudeNoSessionFlag],
                                         environment: environment, timeout: timeout)
        if case .failure(let message) = result, message.contains(claudeNoSessionFlag) {
            return await captureOutput(executable: path, arguments: base, environment: environment, timeout: timeout)
        }
        return result
    }

    static let claudeNoSessionFlag = "--no-session-persistence"

    /// 짧은 명령의 stdout 을 수집한다. stdout/stderr 를 동시에 소비한다.
    /// `stdinLines` 를 주면 한 줄씩 보낸 뒤 stdin 을 닫는다. 긴 내용을 인수로 넘기면
    /// `ps` 로 다른 프로세스에 보이므로, 대화 기록 같은 입력은 이 경로로 보낸다.
    ///
    /// 주의: 종료 코드가 0 이 아니어도 stdout 이 있으면 성공으로 돌려준다 (기존 호출자들의 동작).
    /// 성공 여부를 종료 코드로 판단해야 하는 곳(git 쓰기)은 `captureProcess` 를 쓴다.
    static func captureOutput(executable: String, arguments: [String],
                              environment: [String: String], workingDirectory: URL? = nil,
                              stdinLines: [String] = [],
                              timeout: TimeInterval) async -> CaptureResult {
        let captured = await captureProcess(executable: executable, arguments: arguments,
                                            environment: environment, workingDirectory: workingDirectory,
                                            stdinLines: stdinLines, timeout: timeout)
        if let note = captured.note { return .failure(note) }
        let exitStatus = captured.exitStatus ?? -1  // note 가 없으면 항상 값이 있다
        if exitStatus != 0 && captured.stdout.isEmpty {
            return .failure(captured.stderr.isEmpty ? "종료 코드 \(exitStatus)" : captured.stderr)
        }
        return .success(captured.stdout)
    }

    /// 명령을 끝까지 실행하고 stdout · stderr · 종료 코드를 그대로 돌려준다.
    /// 2026-09-13: pre-commit 훅이 stdout 에 쓰고 실패하면 `captureOutput` 은 성공으로 돌려줘
    /// 커밋하지 못했는데 "커밋했습니다" 가 떴다. git 쓰기는 이 함수로 종료 코드를 본다.
    static func captureProcess(executable: String, arguments: [String],
                               environment: [String: String], workingDirectory: URL? = nil,
                               stdinLines: [String] = [],
                               timeout: TimeInterval) async -> ProcessCapture {
        let proc = ManagedProcess(executable: URL(fileURLWithPath: executable),
                                  arguments: arguments,
                                  workingDirectory: workingDirectory,
                                  environment: environment)
        let stream = proc.makeStream()
        proc.launch()
        if stdinLines.isEmpty {
            proc.closeStdin()
        } else {
            // 파이프 버퍼(64KB)를 넘는 쓰기는 자식이 읽을 때까지 막히므로 협력 스레드 밖에서 쓴다.
            DispatchQueue.global(qos: .userInitiated).async {
                for line in stdinLines {
                    guard proc.writeLine(line) else { break }
                }
                proc.closeStdin()
            }
        }

        var stdout = ""
        var stderr = ""
        var exitStatus: Int32?
        var launchError: String?

        let collector = Task { () -> Void in
            for await out in stream {
                switch out {
                case .stdoutLine(let l): stdout += l + "\n"
                case .stderrLine(let l): stderr += l + "\n"
                case .exited(let s, _): exitStatus = s
                case .launchFailed(let m): launchError = m
                }
            }
        }

        let done = await proc.waitForExit(timeout: timeout)
        if !done {
            _ = await proc.shutdown()
            collector.cancel()
            return ProcessCapture(exitStatus: nil, stdout: stdout, stderr: stderr,
                                  note: "시간 초과(\(Int(timeout))초)")
        }
        // terminationHandler 가 마지막 출력을 흘려보낼 시간을 준다. 부른 작업이 취소돼도 유예는 그대로 둔다
        // (취소로 유예가 0 이 되면 끝난 프로세스의 마지막 출력 — gh 의 JSON 등 — 이 잘려 없던 실패가 된다).
        // 그래서 부른 작업의 취소를 물려받지 않는 작업 안에서 기다린다.
        await Task {
            await withTaskGroup(of: Void.self) { group -> Void in
                group.addTask { await collector.value }
                group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                await group.next()
                // 그룹은 남은 자식을 모두 기다린다 — 출력 받기를 멈춰야 유예가 2초로 끝난다 (멈추지 않으면 파이프를 쥔 자식이 끝날
                // 때까지 기다렸다). 받기가 먼저 끝났으면 아무 일도 하지 않는다.
                collector.cancel()
                group.cancelAll()
            }
        }.value

        if let launchError {
            return ProcessCapture(exitStatus: nil, stdout: stdout, stderr: stderr, note: launchError)
        }
        // 종료 이벤트가 유예 시간 안에 오지 않았어도 (훅이 띄운 자식이 파이프를 쥐고 있는 경우 등) 프로세스는
        // 이미 끝났으므로 종료 코드는 Process 에서 직접 읽는다. 지어낸 값(-1)을 실패로 쓰지 않는다.
        guard let status = exitStatus ?? proc.terminationStatus else {
            return ProcessCapture(exitStatus: nil, stdout: stdout, stderr: stderr, note: "종료 코드를 받지 못했습니다")
        }
        return ProcessCapture(exitStatus: status, stdout: stdout, stderr: stderr, note: nil)
    }
}
