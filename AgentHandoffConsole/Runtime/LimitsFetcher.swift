import Foundation

/// 한도 조회와 파싱. UI 격리와 분리되어 있어 단독 테스트가 가능하다.
enum LimitsFetcher {

    // MARK: - Claude

    /// 현재 설치 버전에서 검증된 경로: `claude -p /usage --output-format json`
    /// 바깥은 JSON 이지만 `result` 안의 한도 정보는 **텍스트**다.
    static func fetchClaude(path: String, environment: [String: String],
                            timeout: TimeInterval = 90) async -> LimitSnapshot {
        var snap = LimitSnapshot(provider: .claude)
        snap.fetchedAt = Date()

        let result = await CLIEnvironment.captureClaudePrint(path: path, command: "/usage", environment: environment,
                                                             timeout: timeout)

        switch result {
        case .failure(let message):
            var status = ErrorClassifier.classify(message)
            if status == .unknownCause { status = .noData }
            snap.status = status
            snap.message = "조회 실패: \(JSONUtil.truncate(message, max: 400))"
            snap.rawResponse = message
            return snap

        case .success(let raw):
            return parseClaudeUsageResponse(raw, into: snap)
        }
    }

    /// `claude -p /usage --output-format json` 응답 전체를 해석한다.
    static func parseClaudeUsageResponse(_ raw: String, into base: LimitSnapshot) -> LimitSnapshot {
        var snap = base
        guard let obj = JSONUtil.object(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = obj["result"] as? String else {
            snap.status = .noData
            snap.message = "응답 형식을 해석하지 못했습니다."
            snap.rawResponse = JSONUtil.truncate(raw, max: 4000)
            return snap
        }
        // 인증 실패에도 subtype=success 가 나온 사례가 있으므로 is_error 와 본문을 함께 본다.
        let isError = obj["is_error"] as? Bool ?? false
        let classification = ErrorClassifier.classify(text)
        if isError || (classification == .authProblem && text.lowercased().contains("error")) {
            snap.status = isError ? (classification == .unknownCause ? .noData : classification)
                                  : classification
            snap.message = JSONUtil.truncate(text, max: 400)
            snap.rawResponse = text
            return snap
        }
        return parseClaudeUsageText(text, into: snap)
    }

    /// `/usage` 텍스트 파서.
    /// 형식이 바뀌면 **0% 로 표시하지 않고** 정보 없음 + 원문 확인으로 대체한다.
    static func parseClaudeUsageText(_ text: String, into base: LimitSnapshot) -> LimitSnapshot {
        var snap = base
        snap.rawResponse = text
        snap.windows = []

        // "이번 주"는 괄호 없는 형식과 "(all models)"만 받는다 — "(Fable)" 같은 모델 한도 줄을 전체 한도로 읽지 않게.
        // 모델 한도는 `model` 을 붙여 보이기만 하고 한도 도달 판정에는 넣지 않는다 (2026-09-22 실측 형식).
        // 창 길이: 현재 세션은 5시간 창, 이번 주는 7일 창이다 (`rate_limit_event` 의 five_hour · seven_day 와 같은 창).
        let specs: [(pattern: String, label: String, model: String?, span: Int)] = [
            ("(?i)current\\s+session\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*%\\s*used([^\\n]*)", "현재 세션", nil, 300),
            ("(?i)current\\s+week(?:\\s*\\(all\\s+models\\))?[^:\\n(]*:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*%\\s*used([^\\n]*)", "이번 주", nil, 10080),
            ("(?i)current\\s+week\\s*\\(fable\\)[^:\\n]*:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*%\\s*used([^\\n]*)", "이번 주 (Fable)", "Fable", 10080),
        ]

        for spec in specs {
            guard let regex = try? NSRegularExpression(pattern: spec.pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 2,
                  let percentRange = Range(match.range(at: 1), in: text),
                  let percent = Double(text[percentRange]) else { continue }

            var window = LimitWindow(label: spec.label, utilization: percent / 100.0, model: spec.model, spanMinutes: spec.span)
            if match.numberOfRanges >= 3, let tailRange = Range(match.range(at: 2), in: text) {
                let tail = text[tailRange]
                    .replacingOccurrences(of: "·", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { window.rawText = tail }
            }
            snap.windows.append(window)
        }

        if snap.windows.isEmpty {
            snap.status = .noData
            snap.message = "한도 텍스트 형식을 인식하지 못했습니다. 원문을 확인하세요."
        } else {
            snap.status = .ok
            snap.message = nil
            if snap.reachedAccountWideCap {
                snap.status = .subscriptionCap
                snap.message = "한도에 도달했습니다."
            }
        }
        return snap
    }

    // MARK: - Codex

    /// `codex app-server` 를 짧게 띄워 `account/rateLimits/read` 를 호출한다.
    ///
    /// 한도는 계정마다 따로다. 어느 계정을 조회하는지는 `environment` 의 `CODEX_HOME` 이 정하며,
    /// `accountID` 는 결과를 그 계정에 붙여 두기 위한 앱 내부 식별자다.
    static func fetchCodex(path: String, environment: [String: String],
                           accountID: String = "",
                           timeout: TimeInterval = 40) async -> LimitSnapshot {
        await fetchCodexWithAccount(path: path, environment: environment, accountID: accountID, timeout: timeout).limits
    }

    /// 한도를 읽는 같은 app-server 에 그 계정이 누구인지(`account/read` — 이메일 · 플랜 · 계정 ID)도 묻는다. 프로세스를 따로 띄우지
    /// 않고, 바깥 연결도 늘지 않는다 — app-server 는 시작할 때 이미 `chatgpt.com` 에 붙고, `account/read` 는 그때 받은 정보로 답한다
    /// (2026-10-07 실측). 그래서 한도 답보다 먼저 오는 것이 보통이고, 늦어도 한도 답 뒤 `accountGrace` 까지만 기다린다 (한도를 늦추지
    /// 않게). 받지 못하면(네트워크 없음 — 로그인된 계정은 오류 · 옛 CLI) `account` 는 nil 이다.
    static func fetchCodexWithAccount(path: String, environment: [String: String],
                                      accountID: String = "",
                                      timeout: TimeInterval = 40,
                                      accountGrace: TimeInterval = 2)
        async -> (limits: LimitSnapshot, account: CodexAccountInspector.AccountRead?) {
        var snap = LimitSnapshot(provider: .codex, accountID: accountID)
        snap.fetchedAt = Date()

        let proc = ManagedProcess(executable: URL(fileURLWithPath: path),
                                  arguments: ["app-server", "--stdio"],
                                  workingDirectory: nil, environment: environment)
        let stream = proc.makeStream()
        proc.launch()

        let collected = UncheckedBox<[String: Any]?>(nil)
        let errorBox = UncheckedBox<String?>(nil)
        let accountBox = UncheckedBox<CodexAccountInspector.AccountRead?>(nil)
        let (limitsArrived, limitsSignal) = AsyncStream<Void>.makeStream()

        let reader = Task {
            var limitsDone = false
            var accountDone = false
            for await out in stream {
                if case .stdoutLine(let line) = out, let obj = JSONUtil.object(line) {
                    let idValue = (obj["id"] as? Int) ?? (obj["id"] as? NSNumber)?.intValue
                    if idValue == 3 {
                        if let result = obj["result"] as? [String: Any] {
                            accountBox.value = CodexAccountInspector.parseAccountRead(result)
                        }
                        accountDone = true
                    } else if idValue == 2 {
                        if let err = obj["error"] as? [String: Any] {
                            errorBox.value = err["message"] as? String ?? "알 수 없는 오류"
                        } else if let result = obj["result"] as? [String: Any] {
                            collected.value = (result["rateLimits"] as? [String: Any]) ?? result
                        }
                        limitsDone = true
                        limitsSignal.yield()
                    }
                    if limitsDone && accountDone { return }
                    continue
                }
                if case .stderrLine(let line) = out, errorBox.value == nil,
                   !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    errorBox.value = line
                }
            }
        }

        _ = proc.writeLine(JSONUtil.line([
            "method": "initialize",
            "params": ["clientInfo": ["name": "AgentHandoffConsole", "version": "0.1.0"]],
            "id": 1,
        ]) ?? "")
        _ = proc.writeLine(JSONUtil.line(["method": "initialized", "params": [:]]) ?? "")
        // 계정 조회를 먼저 — 토큰을 새로 받지 않게 (`refreshToken: false`, auth.json 을 고쳐 쓰지 않는다).
        _ = proc.writeLine(JSONUtil.line([
            "method": "account/read", "params": ["refreshToken": false], "id": 3,
        ]) ?? "")
        _ = proc.writeLine(JSONUtil.line([
            "method": "account/rateLimits/read", "params": [:], "id": 2,
        ]) ?? "")

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await reader.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            group.addTask {
                // 한도 답이 온 뒤 계정 답을 잠깐만 더 기다린다.
                for await _ in limitsArrived {
                    try? await Task.sleep(nanoseconds: UInt64(accountGrace * 1_000_000_000))
                    return
                }
            }
            await group.next()
            // 그룹은 남은 자식을 모두 기다린다 — `reader.value` 를 기다리는 자식이 끝나도록 읽기 작업부터 멈춘다 (멈추지 않으면 답하지 않는
            // app-server 앞에서 이 함수가 끝나지 않았다: 프로세스는 그룹이 끝난 뒤에 끈다).
            reader.cancel()
            group.cancelAll()
        }
        limitsSignal.finish()
        _ = await proc.shutdown()
        let account = accountBox.value

        if let rl = collected.value {
            var parsed = CodexAdapter.parseRateLimits(rl)
            parsed.accountID = accountID
            parsed.fetchedAt = Date()
            return (parsed, account)
        }
        var status = errorBox.value.map { ErrorClassifier.classify($0) } ?? .noData
        if status == .unknownCause { status = .noData }
        snap.status = status
        snap.message = errorBox.value.map { "조회 실패: \(JSONUtil.truncate($0, max: 400))" }
            ?? "한도 조회 응답을 받지 못했습니다."
        return (snap, account)
    }

    // MARK: - Antigravity

    /// `agy -p /usage --output-format json` — 공식 CLI 의 헤드리스 명령이다 (agy 1.1.11 부터, 실측 2026-10-09 agy 1.3.2: 7초 남짓 ·
    /// 토큰 0 · 대화를 만들지 않는다). 예전(2026-09-12, agy 1.2.1)에는 `/usage` 가 대화형 명령뿐이라고 보고 늘 "정보 없음" 으로 두었다.
    /// 한도는 **모델 묶음마다** 따로다 — "Gemini Models"(Gemini Flash · Pro) 와 "Claude and GPT models"(Claude Opus · Sonnet ·
    /// GPT-OSS) 가 각자 주간 · 5시간 창을 갖는다. 그래서 창마다 묶음 이름을 `LimitWindow.model` 에 적는다 — 한 묶음이 차도 다른 묶음의
    /// 모델은 쓸 수 있다 (`reachedAccountWideCap` 에 넣지 않는다). 그 대화의 모델에 맞는 묶음만 볼 때는 `scoped(toAntigravityModel:)`.
    /// language_server 의 localhost RPC · OAuth 토큰으로 Google 내부 API 를 직접 부르는 길은 쓰지 않는다 (문서화되지 않은 내부 프로토콜 ·
    /// Antigravity 로그인의 제3자 재사용).
    static func fetchAntigravity(path: String, environment: [String: String],
                                 timeout: TimeInterval = 60) async -> LimitSnapshot {
        var snap = LimitSnapshot(provider: .gemini)
        snap.fetchedAt = Date()
        // 작업 폴더를 주지 않으면 중립 폴더(빈 임시 폴더)에서 돈다 — 프로젝트를 만들지 않게. stdin 은 닫는다.
        let result = await CLIEnvironment.captureOutput(
            executable: path, arguments: ["-p", "/usage", "--output-format", "json"],
            environment: environment, timeout: timeout)
        switch result {
        case .failure(let message):
            var status = ErrorClassifier.classify(message)
            if status == .unknownCause { status = .noData }
            snap.status = status
            snap.message = "조회 실패: \(JSONUtil.truncate(message, max: 400))"
            snap.rawResponse = message
            return snap
        case .success(let raw):
            return parseAntigravityUsageResponse(raw, into: snap)
        }
    }

    /// 묶음의 짧은 이름 — 창 이름 앞에 붙는다 ("Gemini 5시간").
    static let antigravityGeminiGroup = "Gemini"
    static let antigravityOtherGroup = "Claude · GPT"

    /// CLI 의 묶음 이름 → 짧은 이름. 모르는 묶음은 끝의 "models" 만 떼고 그대로.
    static func antigravityGroupName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("gemini") { return antigravityGeminiGroup }
        if lower.contains("claude") || lower.contains("gpt") { return antigravityOtherGroup }
        let trimmed = raw.replacingOccurrences(of: #"\s*models?\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return trimmed.isEmpty ? raw : trimmed
    }

    /// Antigravity 모델이 쓰는 한도 묶음 — `gemini-…` 는 Gemini, 그 밖(`claude-…` · `gpt-oss-…`)은 Claude · GPT.
    /// 모델을 고르지 않았으면(nil) 앱 기본 모델(가장 최신 Gemini Flash — `ModelCatalog.antigravityDefaultOption`)의 묶음.
    static func antigravityGroup(ofModel identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return antigravityGeminiGroup }
        return identifier.lowercased().hasPrefix("gemini") ? antigravityGeminiGroup : antigravityOtherGroup
    }

    /// `agy -p /usage --output-format json` 응답 전체를 해석한다.
    /// 구조: `{"status":"SUCCESS", "response":"<탭으로 나눈 글>", "command":{"name":"usage","data":{"groups":[{"name",
    /// "buckets":[{"id","name","window":"weekly"|"5h","remaining_fraction":0~1,"reset_time":ISO-8601}]}]}}}`.
    /// `response` 의 글은 100% 로 반올림돼 있어 `command.data` 가 없을 때만 쓴다. 형식이 바뀌면 0% 로 채우지 않고 정보 없음 + 원문.
    /// 모든 창이 100% 남음이어도 그대로 믿는다 (사용자 결정 2026-10-09 — 막 초기화됐거나 쓰지 않은 계정도 그렇게 나온다).
    static func parseAntigravityUsageResponse(_ raw: String, into base: LimitSnapshot) -> LimitSnapshot {
        var snap = base
        snap.windows = []
        guard let obj = JSONUtil.object(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            snap.status = .noData
            snap.message = "응답 형식을 해석하지 못했습니다."
            snap.rawResponse = JSONUtil.truncate(raw, max: 4000)
            return snap
        }
        let status = obj["status"] as? String ?? ""
        let errorText = (obj["error"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if status != "SUCCESS" || errorText != nil {
            let text = errorText ?? (obj["response"] as? String) ?? "status \(status.isEmpty ? "없음" : status)"
            var classified = ErrorClassifier.classify(text)
            if classified == .unknownCause { classified = .noData }
            snap.status = classified
            snap.message = "조회 실패: \(JSONUtil.truncate(text, max: 400))"
            snap.rawResponse = JSONUtil.truncate(raw, max: 4000)
            return snap
        }

        let data = (obj["command"] as? [String: Any])?["data"] as? [String: Any]
        if let groups = data?["groups"] as? [[String: Any]] {
            for group in groups {
                let name = antigravityGroupName(group["name"] as? String ?? "")
                for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                    let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue
                    snap.windows.append(antigravityWindow(group: name, window: bucket["window"] as? String,
                                                          bucketName: bucket["name"] as? String,
                                                          remaining: remaining, reset: bucket["reset_time"]))
                }
            }
        } else if let text = obj["response"] as? String {
            // 묶음 \t 창 이름 \t 남은 % \t 초기화 시각 — 반올림된 값이라 구조가 없을 때만.
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count >= 3, let percent = Double(parts[2].replacingOccurrences(of: "%", with: "")) else { continue }
                let bucketName = parts[1]
                let lower = bucketName.lowercased()
                let window = lower.contains("week") ? "weekly" : (lower.contains("five") || lower.contains("5") ? "5h" : nil)
                snap.windows.append(antigravityWindow(group: antigravityGroupName(parts[0]), window: window, bucketName: bucketName,
                                                      remaining: percent / 100, reset: parts.count > 3 ? parts[3] : nil))
            }
        }

        // 묶음 안에서는 짧은 창 먼저 (Claude · Codex 처럼). 묶음의 순서는 CLI 의 순서.
        let groupOrder = snap.windows.reduce(into: [String]()) { if let g = $1.model, !$0.contains(g) { $0.append(g) } }
        snap.windows = snap.windows.enumerated().sorted { a, b in
            let ga = groupOrder.firstIndex(of: a.element.model ?? "") ?? 0
            let gb = groupOrder.firstIndex(of: b.element.model ?? "") ?? 0
            if ga != gb { return ga < gb }
            let sa = a.element.spanMinutes ?? Int.max, sb = b.element.spanMinutes ?? Int.max
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element)

        guard snap.hasUsableData else {
            snap.status = .noData
            snap.message = "한도 형식을 인식하지 못했습니다. 원문을 확인하세요."
            snap.rawResponse = JSONUtil.truncate(raw, max: 4000)
            return snap
        }
        snap.status = .ok
        snap.message = nil
        // 묶음마다 따로라 한 묶음이 찬 것은 계정 전체의 한도 도달이 아니다 — 모든 묶음에 다 찬 창이 있을 때만.
        let now = Date()
        let fullGroups = Set(snap.windows.filter { ($0.utilization ?? 0) >= 1 && ($0.resetsAt.map { $0 > now } ?? true) }
                                .compactMap(\.model))
        if !groupOrder.isEmpty, Set(groupOrder).isSubset(of: fullGroups) {
            snap.status = .subscriptionCap
            snap.message = "모든 모델 묶음이 한도에 도달했습니다."
        }
        return snap
    }

    private static func antigravityWindow(group: String, window: String?, bucketName: String?,
                                          remaining: Double?, reset: Any?) -> LimitWindow {
        let span: Int?
        let label: String
        switch window?.lowercased() {
        case "5h": span = 300; label = "\(group) 5시간"
        case "weekly": span = 10080; label = "\(group) 7일"
        default: span = nil; label = "\(group) \(bucketName ?? window ?? "한도")"
        }
        let utilization = remaining.map { 1 - min(max($0, 0), 1) }
        return LimitWindow(label: label, utilization: utilization, resetsAt: antigravityDate(reset), model: group, spanMinutes: span)
    }

    /// ISO-8601(소수 초 있거나 없거나) 또는 epoch 초.
    static func antigravityDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

extension LimitSnapshot {
    /// Antigravity 한도를 그 모델이 쓰는 묶음만으로 — 그 묶음의 창을 계정 전체 창(`model` nil)으로 바꿔, 받는 쪽 사실 · 한도 줄의 초기화
    /// 시각(`capResetsAt`) · 한도 도달 판정이 그 대화의 모델 기준이 되게 한다. Antigravity 가 아니거나 그 묶음의 창이 없으면 그대로.
    func scoped(toAntigravityModel identifier: String?) -> LimitSnapshot {
        guard provider == .gemini else { return self }
        let group = LimitsFetcher.antigravityGroup(ofModel: identifier)
        let mine = windows.filter { $0.model == group }
        guard !mine.isEmpty else { return self }
        var scoped = self
        scoped.windows = mine.map { var window = $0; window.model = nil; return window }
        if scoped.status == .ok, scoped.reachedAccountWideCap {
            scoped.status = .subscriptionCap
            scoped.message = "\(group) 모델 묶음이 한도에 도달했습니다."
        }
        return scoped
    }
}

/// 콜백 사이에서 값을 주고받기 위한 얇은 상자.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
