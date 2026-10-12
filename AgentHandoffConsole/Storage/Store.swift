import Foundation

/// 저장 계층. 모든 화면과 메뉴바가 이 인스턴스 하나를 공유한다.
actor Store {
    let db: SQLiteDatabase
    private var seqCache: [String: Int64] = [:]

    init(databaseURL: URL) {
        self.db = SQLiteDatabase(path: databaseURL)
    }

    /// 앱 데이터는 Application Support 에 보관한다. 앱 번들이나 소스 폴더에 두지 않는다.
    static func defaultDatabaseURL() -> URL {
        #if DEBUG
        // 화면 확인용. 실제 기록을 건드리지 않고 데모 DB 로 띄울 때만 쓴다 (Release 빌드에는 없다).
        if let path = ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AgentHandoffConsole", isDirectory: true)
            .appendingPathComponent("handoff.sqlite3")
    }

    func bootstrap() async throws {
        try await db.open()
        try await Migrations.migrate(db)
        try await seedPriceCatalogIfNeeded()
    }

    // MARK: - 설정

    func setting(_ key: String) async throws -> String? {
        let rows = try await db.query("SELECT value FROM app_setting WHERE key = ?;", [.text(key)])
        return rows.first?.text("value")
    }

    func setSetting(_ key: String, _ value: String) async throws {
        try await db.run(
            "INSERT INTO app_setting(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            [.text(key), .text(value)])
    }

    // MARK: - Gemini 보조 결과

    func cachedAssist(kind: String, threadID: String, inputHash: String) async throws -> AssistRecord? {
        try await db.query("""
            SELECT * FROM assist_result
            WHERE kind = ? AND thread_id = ? AND input_hash = ? AND status = 'success'
            ORDER BY created_at DESC LIMIT 1;
            """, [.text(kind), .text(threadID), .text(inputHash)]).first.map(Self.assist)
    }

    func upsertAssist(_ record: AssistRecord) async throws {
        try await db.run("""
            INSERT INTO assist_result(id, kind, thread_id, input_hash, model, output_json,
                                      usage_json, status, created_at, message)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(kind, thread_id, input_hash) DO UPDATE SET
                model = excluded.model, output_json = excluded.output_json,
                usage_json = excluded.usage_json, status = excluded.status,
                created_at = excluded.created_at, message = excluded.message;
            """, [.text(record.id), .text(record.kind), .text(record.threadID),
                  .text(record.inputHash), .optText(record.model), .text(record.outputJSON),
                  .optText(record.usageJSON), .text(record.status),
                  .double(record.createdAt.timeIntervalSince1970), .optText(record.message)])
    }

    // MARK: - 프로젝트

    func projects() async throws -> [Project] {
        try await db.query("SELECT * FROM project ORDER BY sort_order, name;").map(Self.project)
    }

    func upsertProject(_ p: Project) async throws {
        try await db.run("""
            INSERT INTO project(id, name, path, created_at, sort_order)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, path = excluded.path,
                sort_order = excluded.sort_order;
            """, [.text(p.id), .text(p.name), .text(p.path),
                  .double(p.createdAt.timeIntervalSince1970), .int(Int64(p.sortOrder))])
    }

    func deleteProject(id: String) async throws {
        try await db.run("DELETE FROM project WHERE id = ?;", [.text(id)])
    }

    // MARK: - 스레드

    func threads(projectID: String) async throws -> [ConversationThread] {
        try await db.query(
            "SELECT * FROM thread WHERE project_id = ? ORDER BY updated_at DESC;",
            [.text(projectID)]).map(Self.thread)
    }

    func allThreads() async throws -> [ConversationThread] {
        try await db.query("SELECT * FROM thread ORDER BY updated_at DESC;").map(Self.thread)
    }

    func thread(id: String) async throws -> ConversationThread? {
        try await db.query("SELECT * FROM thread WHERE id = ?;", [.text(id)]).first.map(Self.thread)
    }

    func upsertThread(_ t: ConversationThread) async throws {
        try await db.run("""
            INSERT INTO thread(id, project_id, title, goal, pinned_notes, preferred_provider,
                               created_at, updated_at, archived,
                               claude_model, claude_effort, codex_model, codex_effort,
                               gemini_model, gemini_effort, codex_account_id,
                               orchestration_job_id, orchestration_role,
                               worktree_path, worktree_branch, worktree_base_branch, worktree_base_commit)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, goal = excluded.goal,
                pinned_notes = excluded.pinned_notes, preferred_provider = excluded.preferred_provider,
                updated_at = excluded.updated_at, archived = excluded.archived,
                claude_model = excluded.claude_model, claude_effort = excluded.claude_effort,
                codex_model = excluded.codex_model, codex_effort = excluded.codex_effort,
                gemini_model = excluded.gemini_model, gemini_effort = excluded.gemini_effort,
                codex_account_id = excluded.codex_account_id,
                orchestration_job_id = excluded.orchestration_job_id,
                orchestration_role = excluded.orchestration_role,
                worktree_path = excluded.worktree_path, worktree_branch = excluded.worktree_branch,
                worktree_base_branch = excluded.worktree_base_branch,
                worktree_base_commit = excluded.worktree_base_commit;
            """, [.text(t.id), .text(t.projectID), .text(t.title), .text(t.goal),
                  .text(t.pinnedNotes), .text(t.preferredProvider.rawValue),
                  .double(t.createdAt.timeIntervalSince1970),
                  .double(t.updatedAt.timeIntervalSince1970), .bool(t.archived),
                  .optText(t.claudeSelection.model), .optText(t.claudeSelection.effort),
                  .optText(t.codexSelection.model), .optText(t.codexSelection.effort),
                  .optText(t.geminiSelection.model), .optText(t.geminiSelection.effort),
                  .text(t.codexAccountID), .optText(t.orchestrationJobID), .optText(t.orchestrationRole),
                  .optText(t.worktree?.path), .optText(t.worktree?.branch), .optText(t.worktree?.baseBranch),
                  .optText(t.worktree?.baseCommit)])
    }

    /// 대화의 독립 작업 폴더만 바꾼다 (nil 이면 비운다). 행 전체를 옛 복사본으로 덮지 않게 따로 둔다.
    func setThreadWorktree(id: String, worktree: ThreadWorktree?) async throws {
        try await db.run("""
            UPDATE thread SET worktree_path = ?, worktree_branch = ?, worktree_base_branch = ?, worktree_base_commit = ?,
                updated_at = ?
            WHERE id = ?;
            """, [.optText(worktree?.path), .optText(worktree?.branch), .optText(worktree?.baseBranch),
                  .optText(worktree?.baseCommit), .double(Date().timeIntervalSince1970), .text(id)])
    }

    /// 실행 · 인계를 보낸 뒤 스레드에 남길 것만 고친다 — 보낸 에이전트(`onlyIfProviderWas` 가 있으면 지금 값이 그것일 때만),
    /// 자리표시 제목(아직 자리표시일 때만), 비어 있던 모델 채움(아직 비어 있을 때만), 인계로 옮긴 Codex 계정(주었을 때만).
    /// 행 전체를 옛 복사본으로 덮지 않는다 — 실행을 시작하는 동안(시작 전 스냅샷 · CLI 확인) 사용자가 모델 칩 · 에이전트 토글에서
    /// 바꾼 값을 되돌리지 않게. 강도 열은 건드리지 않는다. 한 문장이라 Store 안에서 원자적이다.
    /// 규칙은 `ConversationThread.recordSend` 와 같다 (메모리에 먼저 적용한다).
    func recordThreadSend(id: String, provider: AgentProvider, onlyIfProviderWas: AgentProvider?, placeholderTitle: String?,
                          filledModel: String?, codexAccountID: String?) async throws {
        let modelColumn: String
        switch provider {
        case .claude: modelColumn = "claude_model"
        case .codex: modelColumn = "codex_model"
        case .gemini: modelColumn = "gemini_model"
        }
        // 자리표시 제목 목록은 `ConversationThread.placeholderTitles` 한 곳에서 온다 (메모리 판정과 어긋나지 않게).
        let placeholders = ConversationThread.placeholderTitles.sorted()
        let placeholderList = placeholders.map { _ in "?" }.joined(separator: ", ")
        try await db.run("""
            UPDATE thread SET preferred_provider = CASE WHEN ? IS NULL OR preferred_provider = ? THEN ? ELSE preferred_provider END,
                updated_at = ?,
                title = CASE WHEN ? IS NOT NULL AND title IN (\(placeholderList)) THEN ? ELSE title END,
                \(modelColumn) = CASE WHEN ? IS NOT NULL AND (\(modelColumn) IS NULL OR \(modelColumn) = 'default')
                                      THEN ? ELSE \(modelColumn) END,
                codex_account_id = COALESCE(?, codex_account_id)
            WHERE id = ?;
            """, [.optText(onlyIfProviderWas?.rawValue), .optText(onlyIfProviderWas?.rawValue), .text(provider.rawValue),
                  .double(Date().timeIntervalSince1970),
                  .optText(placeholderTitle)] + placeholders.map { .text($0) } + [.optText(placeholderTitle),
                  .optText(filledModel), .optText(filledModel),
                  .optText(codexAccountID), .text(id)])
    }

    /// 강도를 고르지 않은(비어 있는) 대화의 강도만 정한다 — 그 사이 사람이 고른 값은 덮지 않고, 다른 칸 · 마지막에 쓴 때(`updated_at`)는
    /// 그대로 둔다 (설정의 기본 강도를 바꾸기 전에 이미 쓴 대화의 강도를 정해 둘 때 — `AppModel.setDefaultEffort`, set-n2).
    func pinThreadEffortIfUnset(id: String, provider: AgentProvider, effort: String) async throws {
        let column: String
        switch provider {
        case .claude: column = "claude_effort"
        case .codex: column = "codex_effort"
        case .gemini: column = "gemini_effort"
        }
        try await db.run("UPDATE thread SET \(column) = ? WHERE id = ? AND (\(column) IS NULL OR \(column) = '');",
                         [.text(effort), .text(id)])
    }

    func touchThread(id: String) async throws {
        try await db.run("UPDATE thread SET updated_at = ? WHERE id = ?;",
                         [.double(Date().timeIntervalSince1970), .text(id)])
    }

    func deleteThread(id: String) async throws {
        try await db.run("DELETE FROM thread WHERE id = ?;", [.text(id)])
        seqCache.removeValue(forKey: id)
    }

    // MARK: - 메시지 입력 초안

    struct ComposerDraft: Sendable {
        var text: String
        var revision: Int64
    }

    func composerDraft(threadID: String) async throws -> ComposerDraft? {
        let row = try await db.query(
            "SELECT text, revision FROM composer_draft WHERE thread_id = ?;",
            [.text(threadID)]).first
        guard let row else { return nil }
        return ComposerDraft(text: row.textValue("text"),
                             revision: row.int64Value("revision"))
    }

    /// revision 이 더 최신일 때만 갱신한다. 빠르게 입력할 때 생성된 비동기 저장 작업의
    /// 실행 순서가 바뀌더라도 이전 문자열이 나중 문자열을 덮어쓰지 않는다.
    func setComposerDraft(threadID: String, text: String, revision: Int64) async throws {
        try await db.run("""
            INSERT INTO composer_draft(thread_id, text, revision, updated_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
                text = excluded.text,
                revision = excluded.revision,
                updated_at = excluded.updated_at
            WHERE excluded.revision >= composer_draft.revision;
            """, [.text(threadID), .text(text), .int(revision),
                  .double(Date().timeIntervalSince1970)])
    }

    // MARK: - 에이전트 세션

    func session(threadID: String, provider: AgentProvider,
                 accountID: String = "") async throws -> AgentSession? {
        try await db.query(
            "SELECT * FROM agent_session WHERE thread_id = ? AND provider = ? AND account_id = ?;",
            [.text(threadID), .text(provider.rawValue), .text(accountID)]).first.map(Self.session)
    }

    func sessions(threadID: String) async throws -> [AgentSession] {
        try await db.query("SELECT * FROM agent_session WHERE thread_id = ?;",
                           [.text(threadID)]).map(Self.session)
    }

    /// 세션이 없으면 만들고 반환한다. CLI 세션 ID 는 아직 없을 수 있다.
    ///
    /// 앱은 계정 칸 ""(대화마다 제공자별 하나)만 쓴다 — Codex 도 계정이 바뀌어도 같은 세션이다 (v10, `AgentSession.recordHome`).
    /// 다른 값은 v10 전의 옛 칸을 읽는 시험만 넘긴다.
    func ensureSession(threadID: String, provider: AgentProvider,
                       accountID: String = "") async throws -> AgentSession {
        if let existing = try await session(threadID: threadID, provider: provider,
                                            accountID: accountID) {
            return existing
        }
        let s = AgentSession(threadID: threadID, provider: provider, accountID: accountID)
        try await upsertSession(s)
        return s
    }

    /// 이 CLI 세션 ID 를 가진 세션이 있는지 (기록 가져오기의 중복 방지).
    func sessionExists(cliSessionID: String) async throws -> Bool {
        let rows = try await db.query("SELECT 1 AS x FROM agent_session WHERE cli_session_id = ? LIMIT 1;", [.text(cliSessionID)])
        return !rows.isEmpty
    }

    func upsertSession(_ s: AgentSession) async throws {
        try await db.run("""
            INSERT INTO agent_session(id, thread_id, provider, account_id, cli_session_id,
                                      cli_version, last_delivered_seq, resumable, last_error,
                                      created_at, updated_at, record_home)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, provider, account_id) DO UPDATE SET
                cli_session_id = excluded.cli_session_id,
                cli_version = excluded.cli_version,
                last_delivered_seq = excluded.last_delivered_seq,
                resumable = excluded.resumable,
                last_error = excluded.last_error,
                updated_at = excluded.updated_at,
                record_home = excluded.record_home;
            """, [.text(s.id), .text(s.threadID), .text(s.provider.rawValue),
                  .text(s.accountID), .optText(s.cliSessionID), .optText(s.cliVersion),
                  .int(s.lastDeliveredSeq), .bool(s.resumable), .optText(s.lastError),
                  .double(s.createdAt.timeIntervalSince1970),
                  .double(Date().timeIntervalSince1970), .optText(s.recordHome)])
    }

    // MARK: - 실행

    func insertRun(_ r: Run) async throws {
        try await db.run("""
            INSERT INTO run(id, thread_id, session_id, provider, request_text, state, started_at,
                            ended_at, terminal_reason, model, error_message, child_process_note,
                            is_handoff_delivery, codex_account_id)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text(r.id), .text(r.threadID), .text(r.sessionID), .text(r.provider.rawValue),
                  .text(r.requestText), .text(r.state.rawValue),
                  .double(r.startedAt.timeIntervalSince1970), .date(r.endedAt),
                  .optText(r.terminalReason), .optText(r.model), .optText(r.errorMessage),
                  .optText(r.childProcessNote), .bool(r.isHandoffDelivery),
                  .optText(r.codexAccountID)])
    }

    func updateRun(_ r: Run) async throws {
        try await db.run("""
            UPDATE run SET state = ?, ended_at = ?, terminal_reason = ?, model = ?,
                           error_message = ?, child_process_note = ? WHERE id = ?;
            """, [.text(r.state.rawValue), .date(r.endedAt), .optText(r.terminalReason),
                  .optText(r.model), .optText(r.errorMessage), .optText(r.childProcessNote),
                  .text(r.id)])
    }

    func run(id: String) async throws -> Run? {
        try await db.query("SELECT * FROM run WHERE id = ?;", [.text(id)]).first.map(Self.run)
    }

    func runs(threadID: String) async throws -> [Run] {
        try await db.query("SELECT * FROM run WHERE thread_id = ? ORDER BY started_at;",
                           [.text(threadID)]).map(Self.run)
    }

    /// 앱 재시작 시 남아 있는 활성 실행. 자동으로 완료 처리하지 않고 사용자에게 보여준다.
    func danglingActiveRuns() async throws -> [Run] {
        let active = RunState.allCases.filter { $0.isActive }.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return try await db.query(
            "SELECT * FROM run WHERE state IN (\(active)) ORDER BY started_at DESC;").map(Self.run)
    }

    func allRuns() async throws -> [Run] {
        try await db.query("SELECT * FROM run ORDER BY started_at DESC;").map(Self.run)
    }

    /// 그 시각 뒤에 끝난 실행 — 최근에 끝난 것 먼저 (현황의 "최근 끝난 실행" · 오늘 끝난 수).
    func finishedRuns(since: Date) async throws -> [Run] {
        try await db.query("SELECT * FROM run WHERE ended_at IS NOT NULL AND ended_at >= ? ORDER BY ended_at DESC;",
                           [.double(since.timeIntervalSince1970)]).map(Self.run)
    }

    /// 마지막으로 끝난 실행 (현황의 빈 상태 — "마지막 실행 11:48").
    func lastFinishedRun() async throws -> Run? {
        try await db.query("SELECT * FROM run WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 1;").first.map(Self.run)
    }

    // MARK: - 이벤트

    /// 스레드 내 다음 순번. 실행 중 이벤트를 점진적으로 저장하기 위해 사용한다.
    func nextSeq(threadID: String) async throws -> Int64 {
        if let cached = seqCache[threadID] {
            let next = cached + 1
            seqCache[threadID] = next
            return next
        }
        let rows = try await db.query(
            "SELECT COALESCE(MAX(seq), 0) AS m FROM event WHERE thread_id = ?;", [.text(threadID)])
        let current = rows.first?.int64Value("m") ?? 0
        let next = current + 1
        seqCache[threadID] = next
        return next
    }

    func maxSeq(threadID: String) async throws -> Int64 {
        if let cached = seqCache[threadID] { return cached }
        let rows = try await db.query(
            "SELECT COALESCE(MAX(seq), 0) AS m FROM event WHERE thread_id = ?;", [.text(threadID)])
        let v = rows.first?.int64Value("m") ?? 0
        seqCache[threadID] = v
        return v
    }

    @discardableResult
    func appendEvent(_ e: ThreadEvent) async throws -> ThreadEvent {
        var event = e
        if event.seq == 0 {
            event.seq = try await nextSeq(threadID: event.threadID)
        }
        try await db.run("""
            INSERT INTO event(id, thread_id, run_id, seq, kind, provider, title, text,
                              payload_json, tool_use_id, created_at, is_streaming)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET text = excluded.text, title = excluded.title,
                payload_json = excluded.payload_json, is_streaming = excluded.is_streaming;
            """, [.text(event.id), .text(event.threadID), .optText(event.runID), .int(event.seq),
                  .text(event.kind.rawValue), .optText(event.provider?.rawValue),
                  .text(event.title), .text(event.text), .optText(event.payloadJSON),
                  .optText(event.toolUseID), .double(event.createdAt.timeIntervalSince1970),
                  .bool(event.isStreaming)])
        return event
    }

    func events(threadID: String, afterSeq: Int64 = 0, limit: Int? = nil) async throws -> [ThreadEvent] {
        var sql = "SELECT * FROM event WHERE thread_id = ? AND seq > ? ORDER BY seq"
        var params: [SQLValue] = [.text(threadID), .int(afterSeq)]
        if let limit {
            sql += " LIMIT ?"
            params.append(.int(Int64(limit)))
        }
        sql += ";"
        return try await db.query(sql, params).map(Self.event)
    }

    func recentEvents(threadID: String, limit: Int) async throws -> [ThreadEvent] {
        let rows = try await db.query(
            "SELECT * FROM event WHERE thread_id = ? ORDER BY seq DESC LIMIT ?;",
            [.text(threadID), .int(Int64(limit))])
        return rows.map(Self.event).reversed()
    }

    // MARK: - 붙인 이미지

    /// 이 대화들의 사용자 메시지에 붙은 이미지 파일 경로 (payload `"images"`) — 그 대화의 자동 작업이 만든 내부 대화(대화를 지우면
    /// 함께 지워진다)의 것도. 대화를 지우기 **전에** 읽는다 (`AppModel.deleteThread` → `removeOrphanedAttachments`).
    func imageAttachmentPaths(threadIDs: [String]) async throws -> Set<String> {
        guard !threadIDs.isEmpty else { return [] }
        let list = threadIDs.map { _ in "?" }.joined(separator: ", ")
        let ids: [SQLValue] = threadIDs.map { .text($0) }
        return try await imagePaths(where: """
            thread_id IN (\(list)) OR thread_id IN (
                SELECT id FROM thread WHERE orchestration_job_id IN (
                    SELECT id FROM orchestration_job WHERE parent_thread_id IN (\(list))))
            """, ids + ids)
    }

    /// 이 프로젝트의 모든 대화(내부 대화 포함)의 사용자 메시지에 붙은 이미지 경로 — 프로젝트를 빼기 전에 읽는다.
    func imageAttachmentPaths(projectID: String) async throws -> Set<String> {
        try await imagePaths(where: "thread_id IN (SELECT id FROM thread WHERE project_id = ?)", [.text(projectID)])
    }

    /// 남은 모든 대화의 사용자 메시지가 쓰는 이미지 경로 — 대화를 지운 뒤에 읽어, 아직 쓰는 파일은 남긴다.
    func imageAttachmentPaths() async throws -> Set<String> {
        try await imagePaths(where: "1", [])
    }

    private func imagePaths(where condition: String, _ params: [SQLValue]) async throws -> Set<String> {
        let rows = try await db.query("""
            SELECT * FROM event WHERE kind = ? AND payload_json LIKE ? AND (\(condition));
            """, [.text(EventKind.userMessage.rawValue), .text("%\"images\"%")] + params)
        return Set(rows.map(Self.event).flatMap { $0.imageAttachments.map(\.path) })
    }

    // MARK: - 인계

    func insertHandoff(_ h: Handoff) async throws {
        try await db.run("""
            INSERT INTO handoff(id, thread_id, from_provider, to_provider, from_account_id,
                to_account_id, from_session_id,
                to_session_id, base_seq, packet_version, draft_json, final_text, delivery_state,
                local_token, delivery_run_id, created_at, sent_at, note)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text(h.id), .text(h.threadID), .text(h.fromProvider.rawValue),
                  .text(h.toProvider.rawValue), .text(h.fromAccountID), .text(h.toAccountID),
                  .optText(h.fromSessionID), .optText(h.toSessionID),
                  .int(h.baseSeq), .int(Int64(h.packetVersion)), .text(h.draftJSON),
                  .text(h.finalText), .text(h.deliveryState.rawValue), .text(h.localToken),
                  .optText(h.deliveryRunID), .double(h.createdAt.timeIntervalSince1970),
                  .date(h.sentAt), .optText(h.note)])
    }

    /// 넘길 때 행을 넣는다 — 초안을 만들 때는 넣지 않는다 (취소한 초안이 DB 에 남지 않게). 이미 있으면(다시 보내는 실패 행 ·
    /// 겹친 보내기) 그대로 둔다: 상태는 `claimHandoffForSending` 이 DB 의 값으로 판정한다.
    func insertHandoffIfAbsent(_ h: Handoff) async throws {
        try await db.run("""
            INSERT OR IGNORE INTO handoff(id, thread_id, from_provider, to_provider, from_account_id,
                to_account_id, from_session_id,
                to_session_id, base_seq, packet_version, draft_json, final_text, delivery_state,
                local_token, delivery_run_id, created_at, sent_at, note)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text(h.id), .text(h.threadID), .text(h.fromProvider.rawValue),
                  .text(h.toProvider.rawValue), .text(h.fromAccountID), .text(h.toAccountID),
                  .optText(h.fromSessionID), .optText(h.toSessionID),
                  .int(h.baseSeq), .int(Int64(h.packetVersion)), .text(h.draftJSON),
                  .text(h.finalText), .text(HandoffDeliveryState.draft.rawValue), .text(h.localToken),
                  .optText(nil), .double(h.createdAt.timeIntervalSince1970),
                  .date(nil), .optText(h.note)])
    }

    /// 보낼 내용(초안 JSON · 최종 글 · 검토 표시)만 쓴다 — 전달 상태 · 실행 · 보낸 시각은 건드리지 않고, 초안 · 실패 행에만 쓴다.
    /// 화면이 들고 있던 사본으로 이미 보내는 중 · 끝난 행의 상태를 되돌리지 않게.
    @discardableResult
    func updateHandoffDraftContent(_ h: Handoff) async throws -> Bool {
        try await db.run("""
            UPDATE handoff SET packet_version = ?, draft_json = ?, final_text = ?, note = ?
            WHERE id = ? AND delivery_state IN ('draft', 'failed');
            """, [.int(Int64(h.packetVersion)), .text(h.draftJSON), .text(h.finalText), .optText(h.note),
                  .text(h.id)]) == 1
    }

    /// 인계를 보내기로 점유한다: 초안 · 실패 행만 '전송 중' 으로 바꾸고 true. 이미 보내는 중이거나 끝난 행이면 false —
    /// 같은 인계를 두 번 보내지 않는 마지막 문 (메모리의 사본이 아니라 DB 의 값으로 판정한다).
    /// 보낼 내용(초안 JSON · 최종 글 · 검토 표시)도 같은 쓰기에 적는다 — 점유 직전에 다른 쓰기(재정리 등)가 끼어도
    /// DB 의 인계 글이 실제로 보낸 글과 같게.
    func claimHandoffForSending(_ h: Handoff, sentAt: Date) async throws -> Bool {
        try await db.run("""
            UPDATE handoff SET delivery_state = 'sending', sent_at = ?, packet_version = ?, draft_json = ?,
                final_text = ?, note = ?
            WHERE id = ? AND delivery_state IN ('draft', 'failed');
            """, [.date(sentAt), .int(Int64(h.packetVersion)), .text(h.draftJSON), .text(h.finalText), .optText(h.note),
                  .text(h.id)]) == 1
    }

    /// 전달 실행을 잇는다 (상태는 건드리지 않는다).
    func setHandoffDeliveryRun(id: String, runID: String) async throws {
        try await db.run("UPDATE handoff SET delivery_run_id = ? WHERE id = ?;", [.text(runID), .text(id)])
    }

    /// 앱을 켤 때: 살아 있는 실행이 없는데 '전송 중' 으로 남은 인계(앱이 보내는 도중 죽었다)를 '전달 여부 미확인' 으로.
    /// 자동 인계는 미확인 인계가 있으면 보내지 않는다 — 운명을 모르는 인계 위에 또 보내지 않게. 바꾼 행 수.
    @discardableResult
    func markOrphanedHandoffsUnknown(note: String) async throws -> Int {
        try await db.run("""
            UPDATE handoff SET delivery_state = 'unknown',
                note = CASE WHEN note IS NULL OR note = '' THEN ? ELSE note || ' · ' || ? END
            WHERE delivery_state = 'sending';
            """, [.text(note), .text(note)])
    }

    func updateHandoff(_ h: Handoff) async throws {
        try await db.run("""
            UPDATE handoff SET to_session_id = ?, packet_version = ?, draft_json = ?,
                final_text = ?, delivery_state = ?, delivery_run_id = ?, sent_at = ?, note = ?
            WHERE id = ?;
            """, [.optText(h.toSessionID), .int(Int64(h.packetVersion)), .text(h.draftJSON),
                  .text(h.finalText), .text(h.deliveryState.rawValue), .optText(h.deliveryRunID),
                  .date(h.sentAt), .optText(h.note), .text(h.id)])
    }

    func handoffs(threadID: String) async throws -> [Handoff] {
        try await db.query("SELECT * FROM handoff WHERE thread_id = ? ORDER BY created_at;",
                           [.text(threadID)]).map(Self.handoff)
    }

    func allHandoffs() async throws -> [Handoff] {
        try await db.query("SELECT * FROM handoff ORDER BY created_at DESC;").map(Self.handoff)
    }

    func handoff(localToken: String) async throws -> Handoff? {
        try await db.query("SELECT * FROM handoff WHERE local_token = ?;",
                           [.text(localToken)]).first.map(Self.handoff)
    }

    // MARK: - 사용량

    func upsertUsage(_ u: UsageRecord) async throws {
        try await db.run("""
            INSERT INTO usage_record(id, run_id, thread_id, provider, model, input_tokens,
                cache_read_tokens, cache_write_tokens, output_tokens, reasoning_tokens,
                duration_ms, cost_usd, cost_source, price_catalog_version, confirmed, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
                model = excluded.model,
                input_tokens = excluded.input_tokens,
                cache_read_tokens = excluded.cache_read_tokens,
                cache_write_tokens = excluded.cache_write_tokens,
                output_tokens = excluded.output_tokens,
                reasoning_tokens = excluded.reasoning_tokens,
                duration_ms = excluded.duration_ms,
                cost_usd = excluded.cost_usd,
                cost_source = excluded.cost_source,
                price_catalog_version = excluded.price_catalog_version,
                confirmed = excluded.confirmed;
            """, [.text(u.id), .text(u.runID), .text(u.threadID), .text(u.provider.rawValue),
                  .optText(u.model), .int(Int64(u.inputTokens)), .int(Int64(u.cacheReadTokens)),
                  .int(Int64(u.cacheWriteTokens)), .int(Int64(u.outputTokens)),
                  .int(Int64(u.reasoningTokens)), .int(Int64(u.durationMs)),
                  .optDouble(u.costUSD), .text(u.costSource.rawValue),
                  .optText(u.priceCatalogVersion), .bool(u.confirmed),
                  .double(u.createdAt.timeIntervalSince1970)])
    }

    func usage(threadID: String) async throws -> [UsageRecord] {
        try await db.query("SELECT * FROM usage_record WHERE thread_id = ? ORDER BY created_at;",
                           [.text(threadID)]).map(Self.usage)
    }

    /// 그 시각 뒤에 남긴 사용량 기록 (현황의 끝난 실행 표 — 실행 ID 로 짝짓는다).
    func usage(since: Date) async throws -> [UsageRecord] {
        try await db.query("SELECT * FROM usage_record WHERE created_at >= ? ORDER BY created_at;",
                           [.double(since.timeIntervalSince1970)]).map(Self.usage)
    }

    func allUsage() async throws -> [UsageRecord] {
        try await db.query("SELECT * FROM usage_record ORDER BY created_at DESC;").map(Self.usage)
    }

    // MARK: - 평가

    func upsertRating(_ r: Rating) async throws {
        // run_id / handoff_id 부분 유니크 인덱스와 충돌하지 않도록 먼저 지운다.
        if let runID = r.runID {
            try await db.run("DELETE FROM rating WHERE run_id = ?;", [.text(runID)])
        }
        if let handoffID = r.handoffID {
            try await db.run("DELETE FROM rating WHERE handoff_id = ?;", [.text(handoffID)])
        }
        try await db.run("""
            INSERT INTO rating(id, thread_id, run_id, handoff_id, provider, satisfaction,
                handoff_quality, rescue, note, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text(r.id), .text(r.threadID), .optText(r.runID), .optText(r.handoffID),
                  .text(r.provider.rawValue), .optText(r.satisfaction?.rawValue),
                  .optText(r.handoffQuality?.rawValue), .bool(r.rescue), .optText(r.note),
                  .double(r.createdAt.timeIntervalSince1970),
                  .double(Date().timeIntervalSince1970)])
    }

    func ratings(threadID: String) async throws -> [Rating] {
        try await db.query("SELECT * FROM rating WHERE thread_id = ?;",
                           [.text(threadID)]).map(Self.rating)
    }

    func allRatings() async throws -> [Rating] {
        try await db.query("SELECT * FROM rating ORDER BY created_at DESC;").map(Self.rating)
    }

    // MARK: - 가격표

    func priceEntries() async throws -> [PriceEntry] {
        try await db.query("SELECT * FROM price_entry ORDER BY provider, model;").map(Self.price)
    }

    func upsertPrice(_ p: PriceEntry) async throws {
        let (sql, params) = Self.upsertPriceStatement(p)
        try await db.run(sql, params)
    }

    private static func upsertPriceStatement(_ p: PriceEntry) -> (String, [SQLValue]) {
        ("""
            INSERT INTO price_entry(id, provider, model, input_per_mtok, output_per_mtok,
                cache_read_per_mtok, cache_write_per_mtok, source, effective_date, catalog_version)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, model, catalog_version) DO UPDATE SET
                input_per_mtok = excluded.input_per_mtok,
                output_per_mtok = excluded.output_per_mtok,
                cache_read_per_mtok = excluded.cache_read_per_mtok,
                cache_write_per_mtok = excluded.cache_write_per_mtok,
                source = excluded.source,
                effective_date = excluded.effective_date;
            """, [.text(p.id), .text(p.provider.rawValue), .text(p.model),
                  .double(p.inputPerMTok), .double(p.outputPerMTok),
                  .double(p.cacheReadPerMTok), .double(p.cacheWritePerMTok),
                  .text(p.source), .text(p.effectiveDate), .text(p.catalogVersion)])
    }

    /// 사람이 넣은 가격 한 줄을 지운다 (설정 > 고급 > 가격표). 앱이 넣은 공개 가격의 줄은 지우지 않는다 — 버전이 `user-` 인 줄만.
    func deleteUserPrice(id: String) async throws {
        try await db.run("DELETE FROM price_entry WHERE id = ? AND catalog_version LIKE ?;",
                         [.text(id), .text(PriceCatalog.userVersionPrefix + "%")])
    }

    /// 사람이 넣은 가격 한 줄을 고친다 — 옛 줄을 지우고 새 줄을 넣는 것을 한 트랜잭션으로 (모델 이름을 고쳐도 옛 줄이 남지 않게).
    func replaceUserPrice(id: String, with entry: PriceEntry) async throws {
        try await db.transaction([
            ("DELETE FROM price_entry WHERE id = ? AND catalog_version LIKE ?;",
             [.text(id), .text(PriceCatalog.userVersionPrefix + "%")]),
            Self.upsertPriceStatement(entry),
        ])
    }

    private func seedPriceCatalogIfNeeded() async throws {
        let seeded = try await setting("price_catalog_seeded_version")
        guard seeded != PriceCatalog.version else { return }
        // 앱이 넣은 이전 버전만 치운다. 설정 화면에서 추가한 user-* 가격은 보존한다.
        try await db.run("DELETE FROM price_entry WHERE catalog_version NOT LIKE 'user-%';")
        for entry in PriceCatalog.seed {
            try await upsertPrice(entry)
        }
        try await setSetting("price_catalog_seeded_version", PriceCatalog.version)
    }

    // MARK: - 모델 목록

    /// 모델 목록은 (제공자, 계정) 단위로 캐시한다.
    /// 계정마다 쓸 수 있는 모델이 다를 수 있어 한쪽 목록을 다른 계정에 적용하지 않는다.
    func modelOptions(scope: AgentScope) async throws -> [AgentModelOption] {
        try await db.query(
            """
            SELECT * FROM model_option WHERE provider = ? AND account_id = ?
            ORDER BY sort_order, display_name;
            """,
            [.text(scope.provider.rawValue), .text(scope.accountID)]).map(Self.modelOption)
    }

    func modelCatalogFetchedAt(scope: AgentScope) async throws -> Date? {
        try await db.query(
            "SELECT MAX(fetched_at) AS m FROM model_option WHERE provider = ? AND account_id = ?;",
            [.text(scope.provider.rawValue), .text(scope.accountID)]).first?.date("m")
    }

    /// 한 범위의 목록을 통째로 교체한다. 조회 결과가 줄어든 경우도 반영된다.
    /// 목록을 통째로 바꾼다 — 한 트랜잭션이라 도중에 읽는 쪽(RunCoordinator 의 Antigravity 판정)이 빈 목록 · 반쯤 찬 목록을 보지 않는다.
    func replaceModelOptions(_ options: [AgentModelOption], scope: AgentScope) async throws {
        let now = Date().timeIntervalSince1970
        var statements: [(String, [SQLValue])] = [
            ("DELETE FROM model_option WHERE provider = ? AND account_id = ?;",
             [.text(scope.provider.rawValue), .text(scope.accountID)]),
        ]
        for (index, o) in options.enumerated() {
            statements.append(("""
                INSERT INTO model_option(id, provider, account_id, identifier, display_name, detail,
                    supported_efforts, default_effort, is_default, is_discovered, sort_order, fetched_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [.text("\(scope.accountID)|\(o.id)"), .text(o.provider.rawValue),
                      .text(scope.accountID), .text(o.identifier),
                      .text(o.displayName), .optText(o.detail),
                      .text(o.supportedEfforts.joined(separator: ",")),
                      .optText(o.defaultEffort), .bool(o.isDefault), .bool(o.isDiscovered),
                      .int(Int64(index)), .double(now)]))
        }
        try await db.transaction(statements)
    }

    // MARK: - Codex 계정

    func codexAccounts() async throws -> [CodexAccount] {
        try await db.query("SELECT * FROM codex_account ORDER BY sort_order, created_at;")
            .map(Self.codexAccount)
    }

    func upsertCodexAccount(_ a: CodexAccount) async throws {
        try await db.run("""
            INSERT INTO codex_account(id, label, home_path, sort_order, created_at, auth_status,
                email, plan_type, chatgpt_account_id, auth_mode, token_expires_at,
                identity_checked_at, identity_note)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                label = excluded.label,
                home_path = excluded.home_path,
                sort_order = excluded.sort_order,
                auth_status = excluded.auth_status,
                email = excluded.email,
                plan_type = excluded.plan_type,
                chatgpt_account_id = excluded.chatgpt_account_id,
                auth_mode = excluded.auth_mode,
                token_expires_at = excluded.token_expires_at,
                identity_checked_at = excluded.identity_checked_at,
                identity_note = excluded.identity_note;
            """, [.text(a.id), .text(a.label), .text(a.homePath), .int(Int64(a.sortOrder)),
                  .double(a.createdAt.timeIntervalSince1970), .text(a.authStatus.rawValue),
                  .optText(a.email), .optText(a.planType), .optText(a.chatgptAccountID),
                  .optText(a.authMode), .date(a.tokenExpiresAt), .date(a.identityCheckedAt),
                  .optText(a.identityNote)])
    }

    /// 계정 등록만 지운다. `CODEX_HOME` 폴더와 로그인 상태는 앱이 건드리지 않는다.
    func deleteCodexAccount(id: String) async throws {
        try await db.run("DELETE FROM codex_account WHERE id = ?;", [.text(id)])
    }

    /// 이 계정을 쓰도록 설정된 스레드 수. 삭제 전에 영향을 알려주기 위해 쓴다.
    func threadCount(usingCodexAccount id: String) async throws -> Int {
        try await db.query("SELECT COUNT(*) AS c FROM thread WHERE codex_account_id = ?;",
                           [.text(id)]).first?.intValue("c") ?? 0
    }

    /// 등록이 사라진 계정을 쓰던 스레드를 기본 계정으로 되돌린다.
    /// 세션 기록은 지우지 않는다 — 계정을 다시 등록하면 그대로 이어갈 수 있다.
    @discardableResult
    func reassignThreads(fromCodexAccount id: String, to newID: String) async throws -> Int {
        try await db.run("UPDATE thread SET codex_account_id = ? WHERE codex_account_id = ?;",
                         [.text(newID), .text(id)])
    }

    private static func codexAccount(_ r: SQLRow) -> CodexAccount {
        CodexAccount(
            id: r.textValue("id"), label: r.textValue("label"),
            homePath: r.textValue("home_path"), sortOrder: r.intValue("sort_order"),
            createdAt: r.dateValue("created_at"),
            authStatus: CodexAuthStatus(rawValue: r.textValue("auth_status")) ?? .notLoggedIn,
            email: r.text("email"), planType: r.text("plan_type"),
            chatgptAccountID: r.text("chatgpt_account_id"), authMode: r.text("auth_mode"),
            tokenExpiresAt: r.date("token_expires_at"),
            identityCheckedAt: r.date("identity_checked_at"),
            identityNote: r.text("identity_note"))
    }

    private static func modelOption(_ r: SQLRow) -> AgentModelOption {
        let efforts = r.textValue("supported_efforts")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return AgentModelOption(
            provider: AgentProvider(rawValue: r.textValue("provider")) ?? .claude,
            identifier: r.textValue("identifier"),
            displayName: r.textValue("display_name"),
            detail: r.text("detail"),
            supportedEfforts: efforts,
            defaultEffort: r.text("default_effort"),
            isDefault: r.bool("is_default"),
            isDiscovered: r.bool("is_discovered", default: true))
    }

    // MARK: - CLI 검증 기록

    func recordVerification(provider: AgentProvider, cliVersion: String,
                            capability: String, result: String, detail: String?) async throws {
        try await db.run("""
            INSERT INTO cli_verification(id, provider, cli_version, checked_at, capability, result, detail)
            VALUES(?, ?, ?, ?, ?, ?, ?);
            """, [.text(UUID().uuidString), .text(provider.rawValue), .text(cliVersion),
                  .double(Date().timeIntervalSince1970), .text(capability), .text(result),
                  .optText(detail)])
    }

    func verifications() async throws -> [(provider: String, version: String, capability: String,
                                           result: String, detail: String?, at: Date)] {
        try await db.query("SELECT * FROM cli_verification ORDER BY checked_at DESC LIMIT 200;")
            .map { r in
                (r.textValue("provider"), r.textValue("cli_version"), r.textValue("capability"),
                 r.textValue("result"), r.text("detail"), r.dateValue("checked_at"))
            }
    }

    // MARK: - 행 매핑

    private static func project(_ r: SQLRow) -> Project {
        Project(id: r.textValue("id"), name: r.textValue("name"), path: r.textValue("path"),
                createdAt: r.dateValue("created_at"), sortOrder: r.intValue("sort_order"))
    }

    private static func assist(_ r: SQLRow) -> AssistRecord {
        AssistRecord(id: r.textValue("id"), kind: r.textValue("kind"),
                     threadID: r.textValue("thread_id"), inputHash: r.textValue("input_hash"),
                     model: r.text("model"), outputJSON: r.textValue("output_json"),
                     usageJSON: r.text("usage_json"), status: r.textValue("status"),
                     createdAt: r.dateValue("created_at"), message: r.text("message"))
    }

    private static func thread(_ r: SQLRow) -> ConversationThread {
        ConversationThread(
            id: r.textValue("id"), projectID: r.textValue("project_id"),
            title: r.textValue("title"), goal: r.textValue("goal"),
            pinnedNotes: r.textValue("pinned_notes"),
            preferredProvider: AgentProvider(rawValue: r.textValue("preferred_provider")) ?? .claude,
            codexAccountID: r.textValue("codex_account_id", default: CodexAccount.defaultID),
            claudeSelection: ModelSelection(model: r.text("claude_model"),
                                            effort: r.text("claude_effort")),
            codexSelection: ModelSelection(model: r.text("codex_model"),
                                           effort: r.text("codex_effort")),
            geminiSelection: ModelSelection(model: r.text("gemini_model"),
                                            effort: r.text("gemini_effort")),
            createdAt: r.dateValue("created_at"), updatedAt: r.dateValue("updated_at"),
            archived: r.bool("archived"),
            orchestrationJobID: r.text("orchestration_job_id"), orchestrationRole: r.text("orchestration_role"),
            worktree: r.text("worktree_path").flatMap { path in
                r.text("worktree_branch").map { branch in
                    ThreadWorktree(path: path, branch: branch, baseBranch: r.text("worktree_base_branch"),
                                   baseCommit: r.textValue("worktree_base_commit"))
                }
            })
    }

    private static func session(_ r: SQLRow) -> AgentSession {
        AgentSession(
            id: r.textValue("id"), threadID: r.textValue("thread_id"),
            provider: AgentProvider(rawValue: r.textValue("provider")) ?? .claude,
            accountID: r.textValue("account_id"),
            cliSessionID: r.text("cli_session_id"), cliVersion: r.text("cli_version"),
            lastDeliveredSeq: r.int64Value("last_delivered_seq"),
            resumable: r.bool("resumable", default: true), lastError: r.text("last_error"),
            createdAt: r.dateValue("created_at"), updatedAt: r.dateValue("updated_at"),
            recordHome: r.text("record_home"))
    }

    private static func run(_ r: SQLRow) -> Run {
        Run(id: r.textValue("id"), threadID: r.textValue("thread_id"),
            sessionID: r.textValue("session_id"),
            provider: AgentProvider(rawValue: r.textValue("provider")) ?? .claude,
            requestText: r.textValue("request_text"),
            state: RunState(rawValue: r.textValue("state")) ?? .idle,
            startedAt: r.dateValue("started_at"), endedAt: r.date("ended_at"),
            terminalReason: r.text("terminal_reason"), model: r.text("model"),
            errorMessage: r.text("error_message"), childProcessNote: r.text("child_process_note"),
            isHandoffDelivery: r.bool("is_handoff_delivery"),
            codexAccountID: r.text("codex_account_id"))
    }

    private static func event(_ r: SQLRow) -> ThreadEvent {
        ThreadEvent(
            id: r.textValue("id"), threadID: r.textValue("thread_id"), runID: r.text("run_id"),
            seq: r.int64Value("seq"), kind: EventKind(rawValue: r.textValue("kind")) ?? .systemNotice,
            provider: r.text("provider").flatMap { AgentProvider(rawValue: $0) },
            title: r.textValue("title"), text: r.textValue("text"),
            payloadJSON: r.text("payload_json"), toolUseID: r.text("tool_use_id"),
            createdAt: r.dateValue("created_at"), isStreaming: r.bool("is_streaming"))
    }

    private static func handoff(_ r: SQLRow) -> Handoff {
        Handoff(
            id: r.textValue("id"), threadID: r.textValue("thread_id"),
            fromProvider: AgentProvider(rawValue: r.textValue("from_provider")) ?? .claude,
            toProvider: AgentProvider(rawValue: r.textValue("to_provider")) ?? .codex,
            fromAccountID: r.textValue("from_account_id"),
            toAccountID: r.textValue("to_account_id"),
            fromSessionID: r.text("from_session_id"), toSessionID: r.text("to_session_id"),
            baseSeq: r.int64Value("base_seq"), packetVersion: r.intValue("packet_version", default: 1),
            draftJSON: r.textValue("draft_json"), finalText: r.textValue("final_text"),
            deliveryState: HandoffDeliveryState(rawValue: r.textValue("delivery_state")) ?? .draft,
            localToken: r.textValue("local_token"), deliveryRunID: r.text("delivery_run_id"),
            createdAt: r.dateValue("created_at"), sentAt: r.date("sent_at"), note: r.text("note"))
    }

    private static func usage(_ r: SQLRow) -> UsageRecord {
        UsageRecord(
            id: r.textValue("id"), runID: r.textValue("run_id"), threadID: r.textValue("thread_id"),
            provider: AgentProvider(rawValue: r.textValue("provider")) ?? .claude,
            model: r.text("model"), inputTokens: r.intValue("input_tokens"),
            cacheReadTokens: r.intValue("cache_read_tokens"),
            cacheWriteTokens: r.intValue("cache_write_tokens"),
            outputTokens: r.intValue("output_tokens"),
            reasoningTokens: r.intValue("reasoning_tokens"),
            durationMs: r.intValue("duration_ms"), costUSD: r.double("cost_usd"),
            costSource: CostSource(rawValue: r.textValue("cost_source")) ?? .unknown,
            priceCatalogVersion: r.text("price_catalog_version"),
            confirmed: r.bool("confirmed", default: true), createdAt: r.dateValue("created_at"))
    }

    private static func rating(_ r: SQLRow) -> Rating {
        Rating(
            id: r.textValue("id"), threadID: r.textValue("thread_id"), runID: r.text("run_id"),
            handoffID: r.text("handoff_id"),
            provider: AgentProvider(rawValue: r.textValue("provider")) ?? .claude,
            satisfaction: r.text("satisfaction").flatMap { Satisfaction(rawValue: $0) },
            handoffQuality: r.text("handoff_quality").flatMap { HandoffQuality(rawValue: $0) },
            rescue: r.bool("rescue"), note: r.text("note"),
            createdAt: r.dateValue("created_at"), updatedAt: r.dateValue("updated_at"))
    }

    private static func price(_ r: SQLRow) -> PriceEntry {
        PriceEntry(
            id: r.textValue("id"),
            provider: AgentProvider(rawValue: r.textValue("provider")) ?? .claude,
            model: r.textValue("model"), inputPerMTok: r.double("input_per_mtok") ?? 0,
            outputPerMTok: r.double("output_per_mtok") ?? 0,
            cacheReadPerMTok: r.double("cache_read_per_mtok") ?? 0,
            cacheWritePerMTok: r.double("cache_write_per_mtok") ?? 0,
            source: r.textValue("source"), effectiveDate: r.textValue("effective_date"),
            catalogVersion: r.textValue("catalog_version"))
    }
}
