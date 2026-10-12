import Foundation

// MARK: - Antigravity 의 흐르는 글 (stream-json `text_delta`)

/// agy 1.3.2 는 stream-json 에서 응답 본문을 `step_update`(`agent_response`)의 `text_delta` 로 흘려 보낸다 (2026-10-09 실측 —
/// `scripts/probe/antigravity-stream`). 어댑터가 조각을 흐르는 글로 넘기고, 단계가 끝나면 그 단계의 글을 한 메시지로 확정하며,
/// 마지막 `result.response` 를 다시 내지 않는지 — 실측 기록을 가짜 agy 로 재생해 본다. 흘려 보내지 않는 옛 agy · 도구를 사이에 둔
/// 두 응답 단계(1.3.2 에서 재지 못한 모양)는 합성한다.
enum AntigravityStreamTests {
    static func run(_ t: TestKit) async {
        await t.group("Antigravity: 흐르는 글 (stream-json text_delta)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-fake-agy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        if let records = await ProbeLogs.require(t, probe: "antigravity-stream", name: "s1") {
            let lines = records.compactMap { record in record.event.map { JSONUtil.string($0) } }
            let response = records.compactMap { ($0.event?["result"] as? [String: Any])?["response"] as? String }.last ?? ""
            let events = await drive(fakeAgy(dir, lines), dir)
            let deltas = events.compactMap { if case .assistantDelta(let d) = $0 { return d }; return nil }
            await t.equal("조각마다 흐르는 글 (60개)", deltas.count, 60)
            await t.check("조각을 이은 글 = result.response (증분 — 누적이 아니다)", !response.isEmpty && deltas.joined() == response,
                          "\(deltas.joined().count)자 · \(response.count)자")
            await t.equal("확정 메시지는 하나 (result.response 를 다시 내지 않는다)", messages(events),
                          [response.trimmingCharacters(in: .whitespacesAndNewlines)])
            let result = finished(events)
            await t.check("실행은 완료 · 결과 글 · 사용량", result?.state == .completed
                            && result?.resultText == response.trimmingCharacters(in: .whitespacesAndNewlines)
                            && result?.usage?.outputTokens == 219, "\(String(describing: result))")
        }

        // 흘려 보내지 않는 옛 agy: 응답 단계에 조각이 없다 → result.response 가 메시지 하나.
        let old = await drive(fakeAgy(dir, [
            JSONUtil.string(["event": "init", "conversation_id": "c-old", "init": ["model": "gemini-3.8-flash"]]),
            JSONUtil.string(["event": "step_update", "step_update": ["step_index": 1, "state": "DONE", "step_type": "agent_response"]]),
            JSONUtil.string(["event": "result", "result": ["status": "SUCCESS", "response": "옛 agy 의 답\n", "conversation_id": "c-old"]]),
        ]), dir)
        await t.check("옛 agy: 흐르는 글 없이 result.response 하나", messages(old) == ["옛 agy 의 답"] && !old.contains {
            if case .assistantDelta = $0 { return true }; return false })

        // 도구를 사이에 둔 응답 단계 둘 (1.3.2 의 도구 단계는 재지 못했다 — 합성): 단계마다 메시지, result 로 겹치지 않는다.
        func step(_ index: Int, _ state: String, _ delta: String?) -> String {
            var update: [String: Any] = ["step_index": index, "state": state, "step_type": "agent_response"]
            if let delta { update["text_delta"] = delta }
            return JSONUtil.string(["event": "step_update", "step_update": update])
        }
        let tool: [String: Any] = ["step_index": 2, "step_type": "tool", "tool_name": "view_file",
                                   "tool_info": ["name": "view_file", "parameters": ["AbsolutePath": "/tmp/a.txt"]]]
        var toolDone = tool
        toolDone["state"] = "DONE"
        var toolActive = tool
        toolActive["state"] = "ACTIVE"
        let two = await drive(fakeAgy(dir, [
            JSONUtil.string(["event": "init", "conversation_id": "c-two", "init": ["model": "gemini-3.8-flash"]]),
            step(1, "ACTIVE", "먼저 "), step(1, "DONE", "읽겠습니다.\n"),
            JSONUtil.string(["event": "step_update", "step_update": toolActive]),
            JSONUtil.string(["event": "step_update", "step_update": toolDone]),
            step(3, "ACTIVE", "다 "), step(3, "DONE", "읽었습니다."),
            JSONUtil.string(["event": "result", "result": ["status": "SUCCESS", "response": "먼저 읽겠습니다.\n다 읽었습니다.",
                                                           "conversation_id": "c-two"]]),
        ]), dir)
        await t.equal("도구를 사이에 둔 응답 단계: 단계마다 메시지, result 로 다시 내지 않는다", messages(two),
                      ["먼저 읽겠습니다.", "다 읽었습니다."])
    }

    /// 표준 입력을 다 읽은 뒤 주어진 줄을 내고 끝나는 가짜 agy.
    private static func fakeAgy(_ dir: URL, _ lines: [String]) -> String {
        let url = dir.appendingPathComponent("agy-\(UUID().uuidString.prefix(8))")
        let body = lines.joined(separator: "\n")
        let script = "#!/bin/bash\ncat > /dev/null\ncat <<'AHC_FAKE_AGY_END'\n\(body)\nAHC_FAKE_AGY_END\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// 어댑터를 끝까지 돌려 이벤트를 모은다 (20초면 끈다).
    private static func drive(_ executable: String, _ dir: URL) async -> [AgentEvent] {
        let adapter = AntigravityAdapter(executablePath: executable, environment: ["PATH": "/usr/bin:/bin"], cliVersion: "1.3.2")
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { _ = await adapter.shutdown() }
        }
        defer { watchdog.cancel() }
        let request = AgentTurnRequest(runID: "r", prompt: "p", workingDirectory: dir)
        var events: [AgentEvent] = []
        for await event in adapter.start(request) { events.append(event) }
        return events
    }

    private static func messages(_ events: [AgentEvent]) -> [String] {
        events.compactMap { if case .assistantMessage(let text) = $0 { return text }; return nil }
    }

    private static func finished(_ events: [AgentEvent]) -> AgentTurnResult? {
        events.compactMap { if case .finished(let result) = $0 { return result }; return nil }.last
    }
}
