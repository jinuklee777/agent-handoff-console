import Foundation

/// 스키마 마이그레이션. user_version 을 기준으로 순서대로 적용한다.
///
/// 단계마다 실행기가 트랜잭션으로 감싸고 같은 트랜잭션에서 user_version 을 올린다
/// (`SQLiteDatabase.applyMigration`). 그래서 단계 SQL 에는 `BEGIN` · `COMMIT` · `PRAGMA foreign_keys` 를
/// 쓰지 않는다 — 중첩 트랜잭션 오류가 나고, 트랜잭션 안의 PRAGMA foreign_keys 는 무시된다.
/// 테이블을 다시 만드느라 외래 키 검사를 꺼야 하는 단계는 `foreignKeysOff` 로 표시한다.
enum Migrations {

    struct Step {
        let version: Int
        let sql: String
        var foreignKeysOff = false
    }

    static let all: [Step] = [
        Step(version: 1, sql: v1),
        Step(version: 2, sql: v2),
        Step(version: 3, sql: v3, foreignKeysOff: true),
        Step(version: 4, sql: v4),
        Step(version: 5, sql: v5),
        Step(version: 6, sql: v6),
        Step(version: 7, sql: v7),
        Step(version: 8, sql: v8),
        Step(version: 9, sql: v9),
        Step(version: 10, sql: v10),
    ]

    static func migrate(_ db: SQLiteDatabase, steps: [Step] = all) async throws {
        let current = try await db.userVersion()
        for step in steps where step.version > current {
            try await db.applyMigration(sql: step.sql, version: step.version,
                                        foreignKeysOff: step.foreignKeysOff)
        }
    }

    // MARK: v10 — 대화마다 Codex 세션 하나 (계정을 바꿔도 같은 세션)
    //
    // Codex 세션을 (대화, 제공자, 계정) 칸이 아니라 대화의 칸 하나(계정 칸 '')에 두고, 그 기록이 있는 CODEX_HOME(기록 폴더)을 함께
    // 적는다 — 다른 계정으로 보내면 그 실행만 그 계정의 인증으로 같은 세션을 재개한다 (`CodexRunHome`). 대화마다 계정별로 갈라져 있던
    // 옛 칸 가운데 세션 ID 가 있는 것을 먼저, 그다음 가장 최근에 쓴 것 하나를 대화의 칸으로 옮긴다 (기록 폴더 = 그 계정의 폴더 — 계정
    // 목록에 없는 계정이면 NULL, 실행 계정의 폴더로 본다). 옛 칸은 지우지 않는다 (옛 빌드가 읽는다 · 기록 가져오기의 중복 확인).
    private static let v10 = """
    ALTER TABLE agent_session ADD COLUMN record_home TEXT;
    INSERT INTO agent_session(id, thread_id, provider, account_id, cli_session_id, cli_version, last_delivered_seq,
                              resumable, last_error, created_at, updated_at, record_home)
    SELECT lower(hex(randomblob(16))), s.thread_id, 'codex', '', s.cli_session_id, s.cli_version, s.last_delivered_seq,
           s.resumable, s.last_error, s.created_at, s.updated_at, a.home_path
    FROM agent_session s
    LEFT JOIN codex_account a ON a.id = s.account_id
    WHERE s.provider = 'codex' AND s.account_id <> ''
      AND s.id = (SELECT s2.id FROM agent_session s2
                  WHERE s2.thread_id = s.thread_id AND s2.provider = 'codex' AND s2.account_id <> ''
                  ORDER BY (s2.cli_session_id IS NULL OR s2.cli_session_id = ''), s2.updated_at DESC, s2.id
                  LIMIT 1)
      AND NOT EXISTS (SELECT 1 FROM agent_session x
                      WHERE x.thread_id = s.thread_id AND x.provider = 'codex' AND x.account_id = '');
    """

    // MARK: v9 — 대화별 독립 작업 폴더 (git worktree)
    //
    // 대화가 프로젝트 폴더 대신 자기 worktree 에서 일할 때 그 경로 · 브랜치 · 가지를 친 본 브랜치 · 커밋. 모두 비어 있으면 프로젝트 폴더.
    // 옛 빌드는 모르는 열을 읽지 않는다 (그 대화를 프로젝트 폴더에서 돌린다).
    private static let v9 = """
    ALTER TABLE thread ADD COLUMN worktree_path TEXT;
    ALTER TABLE thread ADD COLUMN worktree_branch TEXT;
    ALTER TABLE thread ADD COLUMN worktree_base_branch TEXT;
    ALTER TABLE thread ADD COLUMN worktree_base_commit TEXT;
    """

    // MARK: v8 — 오케스트레이션의 내부 대화와 시도 요약
    //
    // 계획 · 검토 · 하위 작업은 각자 내부 대화에서 돈다 (세션과 맥락을 나누려고). 그 대화는 사이드바에 보이지 않는다.
    // 부모 대화를 지우면 전체 작업이 지워지고, 전체 작업이 지워질 때 내부 대화도 함께 지운다 (트리거).
    // 시도의 결과 요약은 뒤 작업에 선행 결과로 넘기는 글이다.
    // (아래 BEGIN … END 는 트리거 본문의 문법이며 트랜잭션이 아니다.)
    private static let v8 = """
    ALTER TABLE thread ADD COLUMN orchestration_job_id TEXT;
    ALTER TABLE thread ADD COLUMN orchestration_role TEXT;
    CREATE INDEX idx_thread_orch_job ON thread(orchestration_job_id);
    ALTER TABLE orchestration_attempt ADD COLUMN result_summary TEXT;
    CREATE TRIGGER trg_orch_job_delete_threads AFTER DELETE ON orchestration_job
    BEGIN
        DELETE FROM thread WHERE orchestration_job_id = OLD.id;
    END;
    """

    // MARK: v7 — 작업 오케스트레이션
    //
    // 전체 작업 → 계획(버전) → 하위 작업 → 시도. 기존 run · event 는 건드리지 않고 시도가 run 을 가리킨다.
    // 상태가 바뀔 때마다 orchestration_transition 에 한 줄 남긴다 (앱 재시작 복구와 "왜 이렇게 됐나"의 근거).
    // 프로젝트나 부모 대화를 지우면 함께 지워진다. 실행 기록(run)이 먼저 지워지면 시도의 run_id 만 비운다.
    // 정책 버전 · 정책 평가 테이블은 그 단계(관측 · 평가)에서 추가한다.
    private static let v7 = """
    CREATE TABLE orchestration_job (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
        parent_thread_id TEXT NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
        user_request_event_id TEXT,
        request TEXT NOT NULL,
        state TEXT NOT NULL,
        active_plan_version INTEGER NOT NULL DEFAULT 0,
        generation INTEGER NOT NULL DEFAULT 0,
        replan_count INTEGER NOT NULL DEFAULT 0,
        final_verification TEXT NOT NULL DEFAULT 'notStarted',
        budget_json TEXT NOT NULL,
        policy_version TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX idx_orch_job_thread ON orchestration_job(parent_thread_id, created_at DESC);
    CREATE INDEX idx_orch_job_state ON orchestration_job(state);

    CREATE TABLE orchestration_plan (
        job_id TEXT NOT NULL REFERENCES orchestration_job(id) ON DELETE CASCADE,
        version INTEGER NOT NULL,
        planner_run_id TEXT,
        schema_version INTEGER NOT NULL,
        plan_json TEXT NOT NULL,
        source_hash TEXT NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY (job_id, version)
    );

    CREATE TABLE orchestration_task (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES orchestration_job(id) ON DELETE CASCADE,
        plan_version INTEGER NOT NULL,
        plan_task_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        title TEXT NOT NULL,
        specification TEXT NOT NULL,
        kind TEXT NOT NULL,
        difficulty INTEGER NOT NULL,
        acceptance_json TEXT NOT NULL,
        verification TEXT NOT NULL,
        paths_json TEXT NOT NULL,
        optional INTEGER NOT NULL DEFAULT 0,
        state TEXT NOT NULL,
        child_thread_id TEXT REFERENCES thread(id) ON DELETE SET NULL,
        blocked_reason TEXT,
        UNIQUE(job_id, plan_version, plan_task_id)
    );
    CREATE INDEX idx_orch_task_job ON orchestration_task(job_id, plan_version, ordinal);

    CREATE TABLE orchestration_dependency (
        task_id TEXT NOT NULL REFERENCES orchestration_task(id) ON DELETE CASCADE,
        depends_on_task_id TEXT NOT NULL REFERENCES orchestration_task(id) ON DELETE CASCADE,
        PRIMARY KEY (task_id, depends_on_task_id),
        CHECK (task_id <> depends_on_task_id)
    );

    CREATE TABLE orchestration_attempt (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES orchestration_task(id) ON DELETE CASCADE,
        job_id TEXT NOT NULL REFERENCES orchestration_job(id) ON DELETE CASCADE,
        attempt_number INTEGER NOT NULL,
        kind TEXT NOT NULL,
        profile_id TEXT NOT NULL,
        routing_decision_id TEXT,
        run_id TEXT REFERENCES run(id) ON DELETE SET NULL,
        dispatch_token TEXT NOT NULL UNIQUE,
        generation INTEGER NOT NULL,
        state TEXT NOT NULL,
        failure_class TEXT,
        failure_fingerprint TEXT,
        created_at REAL NOT NULL,
        ended_at REAL,
        UNIQUE(task_id, attempt_number)
    );
    CREATE INDEX idx_orch_attempt_job ON orchestration_attempt(job_id);
    CREATE INDEX idx_orch_attempt_run ON orchestration_attempt(run_id);

    CREATE TABLE orchestration_transition (
        id INTEGER PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES orchestration_job(id) ON DELETE CASCADE,
        entity TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        from_state TEXT,
        to_state TEXT NOT NULL,
        cause TEXT NOT NULL DEFAULT '',
        sequence INTEGER NOT NULL,
        created_at REAL NOT NULL,
        UNIQUE(job_id, sequence)
    );

    CREATE TABLE verification_result (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES orchestration_job(id) ON DELETE CASCADE,
        task_id TEXT REFERENCES orchestration_task(id) ON DELETE CASCADE,
        attempt_id TEXT REFERENCES orchestration_attempt(id) ON DELETE CASCADE,
        verifier_version TEXT NOT NULL,
        criterion TEXT NOT NULL,
        outcome TEXT NOT NULL,
        evidence_json TEXT NOT NULL,
        workspace_fingerprint TEXT,
        created_at REAL NOT NULL
    );
    CREATE INDEX idx_verification_job ON verification_result(job_id, created_at);

    CREATE TABLE routing_decision (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES orchestration_job(id) ON DELETE CASCADE,
        task_id TEXT REFERENCES orchestration_task(id) ON DELETE CASCADE,
        feature_source TEXT NOT NULL,
        feature_version TEXT NOT NULL,
        input_hash TEXT NOT NULL,
        input_summary TEXT NOT NULL,
        features_json TEXT NOT NULL,
        candidates_json TEXT NOT NULL,
        selected_profile TEXT,
        reason_codes_json TEXT NOT NULL,
        policy_version TEXT NOT NULL,
        latency_ms INTEGER,
        usage_json TEXT,
        created_at REAL NOT NULL
    );
    CREATE INDEX idx_routing_job ON routing_decision(job_id, created_at);
    """

    // MARK: v6 — Antigravity 모델 선택 분리

    /// Antigravity 선택이 Codex 선택과 같은 컬럼을 쓰지 않도록 대화별로 따로 저장한다.
    private static let v6 = """
    ALTER TABLE thread ADD COLUMN gemini_model TEXT;
    ALTER TABLE thread ADD COLUMN gemini_effort TEXT;
    UPDATE thread
    SET gemini_model = codex_model, gemini_effort = codex_effort
    WHERE preferred_provider = 'gemini';
    """

    // MARK: v5 — Gemini 보조 결과 캐시

    private static let v5 = """
    CREATE TABLE IF NOT EXISTS assist_result (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        thread_id TEXT NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
        input_hash TEXT NOT NULL,
        model TEXT,
        output_json TEXT NOT NULL DEFAULT '',
        usage_json TEXT,
        status TEXT NOT NULL,
        created_at REAL NOT NULL,
        message TEXT,
        UNIQUE(kind, thread_id, input_hash)
    );
    CREATE INDEX IF NOT EXISTS idx_assist_thread ON assist_result(thread_id, created_at DESC);
    """

    // MARK: v4 — 대화별 입력 초안

    /// 메시지 입력 중 화면이나 스레드를 바꿔도 초안이 섞이거나 사라지지 않도록
    /// 스레드와 1:1로 저장한다. revision 은 비동기 저장 순서가 뒤바뀌어도
    /// 오래된 입력이 최신 초안을 덮지 못하게 한다.
    private static let v4 = """
    CREATE TABLE IF NOT EXISTS composer_draft (
        thread_id TEXT PRIMARY KEY REFERENCES thread(id) ON DELETE CASCADE,
        text TEXT NOT NULL DEFAULT '',
        revision INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL
    );
    """

    // MARK: v3 — Codex 계정 (CODEX_HOME 분리)
    //
    // 세션의 정체성이 (스레드, 제공자) 에서 (스레드, 제공자, 계정) 으로 바뀐다.
    // Codex 세션 기록은 CODEX_HOME 아래에 있어 계정이 다르면 재개할 수 없기 때문이다.
    // 기존 Codex 기록은 모두 CLI 기본 홈에서 만들어졌으므로 'codex-default' 로 연결한다.
    //
    // SQLite 는 인라인 UNIQUE 를 떼어낼 수 없어 agent_session 은 테이블을 다시 만든다.
    // 그동안 foreign_keys 를 꺼야 하므로 이 단계는 `foreignKeysOff` 로 표시한다 (끄고 켜는 일은 실행기가 한다).
    private static let v3 = """
    CREATE TABLE IF NOT EXISTS codex_account (
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        home_path TEXT NOT NULL UNIQUE,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        auth_status TEXT NOT NULL DEFAULT 'notLoggedIn',
        email TEXT,
        plan_type TEXT,
        chatgpt_account_id TEXT,
        auth_mode TEXT,
        token_expires_at REAL,
        identity_checked_at REAL,
        identity_note TEXT
    );

    ALTER TABLE thread ADD COLUMN codex_account_id TEXT NOT NULL DEFAULT 'codex-default';
    ALTER TABLE run ADD COLUMN codex_account_id TEXT;
    ALTER TABLE handoff ADD COLUMN from_account_id TEXT NOT NULL DEFAULT '';
    ALTER TABLE handoff ADD COLUMN to_account_id TEXT NOT NULL DEFAULT '';

    UPDATE run SET codex_account_id = 'codex-default' WHERE provider = 'codex';
    UPDATE handoff SET from_account_id = 'codex-default' WHERE from_provider = 'codex';
    UPDATE handoff SET to_account_id = 'codex-default' WHERE to_provider = 'codex';

    CREATE TABLE agent_session_v3 (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
        provider TEXT NOT NULL,
        account_id TEXT NOT NULL DEFAULT '',
        cli_session_id TEXT,
        cli_version TEXT,
        last_delivered_seq INTEGER NOT NULL DEFAULT 0,
        resumable INTEGER NOT NULL DEFAULT 1,
        last_error TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(thread_id, provider, account_id)
    );
    INSERT INTO agent_session_v3(id, thread_id, provider, account_id, cli_session_id, cli_version,
                                 last_delivered_seq, resumable, last_error, created_at, updated_at)
        SELECT id, thread_id, provider,
               CASE WHEN provider = 'codex' THEN 'codex-default' ELSE '' END,
               cli_session_id, cli_version, last_delivered_seq, resumable, last_error,
               created_at, updated_at
        FROM agent_session;
    DROP TABLE agent_session;
    ALTER TABLE agent_session_v3 RENAME TO agent_session;

    -- 모델 목록은 계정별로 다를 수 있다. 캐시라 버리고 다음 조회에서 다시 채운다.
    DROP TABLE IF EXISTS model_option;
    CREATE TABLE model_option (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        account_id TEXT NOT NULL DEFAULT '',
        identifier TEXT NOT NULL,
        display_name TEXT NOT NULL,
        detail TEXT,
        supported_efforts TEXT NOT NULL DEFAULT '',
        default_effort TEXT,
        is_default INTEGER NOT NULL DEFAULT 0,
        is_discovered INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL DEFAULT 0,
        fetched_at REAL NOT NULL,
        UNIQUE(provider, account_id, identifier)
    );
    """

    // MARK: v2 — 모델 선택과 모델 목록 캐시

    private static let v2 = """
    ALTER TABLE thread ADD COLUMN claude_model TEXT;
    ALTER TABLE thread ADD COLUMN claude_effort TEXT;
    ALTER TABLE thread ADD COLUMN codex_model TEXT;
    ALTER TABLE thread ADD COLUMN codex_effort TEXT;

    CREATE TABLE IF NOT EXISTS model_option (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        identifier TEXT NOT NULL,
        display_name TEXT NOT NULL,
        detail TEXT,
        supported_efforts TEXT NOT NULL DEFAULT '',
        default_effort TEXT,
        is_default INTEGER NOT NULL DEFAULT 0,
        is_discovered INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL DEFAULT 0,
        fetched_at REAL NOT NULL,
        UNIQUE(provider, identifier)
    );
    """

    // MARK: v1

    private static let v1 = """
    CREATE TABLE IF NOT EXISTS project (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        created_at REAL NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS thread (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        goal TEXT NOT NULL DEFAULT '',
        pinned_notes TEXT NOT NULL DEFAULT '',
        preferred_provider TEXT NOT NULL DEFAULT 'claude',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_thread_project ON thread(project_id, updated_at DESC);

    CREATE TABLE IF NOT EXISTS agent_session (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
        provider TEXT NOT NULL,
        cli_session_id TEXT,
        cli_version TEXT,
        last_delivered_seq INTEGER NOT NULL DEFAULT 0,
        resumable INTEGER NOT NULL DEFAULT 1,
        last_error TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(thread_id, provider)
    );

    CREATE TABLE IF NOT EXISTS run (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
        session_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        request_text TEXT NOT NULL DEFAULT '',
        state TEXT NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL,
        terminal_reason TEXT,
        model TEXT,
        error_message TEXT,
        child_process_note TEXT,
        is_handoff_delivery INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_run_thread ON run(thread_id, started_at DESC);
    CREATE INDEX IF NOT EXISTS idx_run_state ON run(state);

    CREATE TABLE IF NOT EXISTS event (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
        run_id TEXT,
        seq INTEGER NOT NULL,
        kind TEXT NOT NULL,
        provider TEXT,
        title TEXT NOT NULL DEFAULT '',
        text TEXT NOT NULL DEFAULT '',
        payload_json TEXT,
        tool_use_id TEXT,
        created_at REAL NOT NULL,
        is_streaming INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_event_thread_seq ON event(thread_id, seq);
    CREATE INDEX IF NOT EXISTS idx_event_run ON event(run_id);

    CREATE TABLE IF NOT EXISTS handoff (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
        from_provider TEXT NOT NULL,
        to_provider TEXT NOT NULL,
        from_session_id TEXT,
        to_session_id TEXT,
        base_seq INTEGER NOT NULL,
        packet_version INTEGER NOT NULL,
        draft_json TEXT NOT NULL,
        final_text TEXT NOT NULL,
        delivery_state TEXT NOT NULL,
        local_token TEXT NOT NULL UNIQUE,
        delivery_run_id TEXT,
        created_at REAL NOT NULL,
        sent_at REAL,
        note TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_handoff_thread ON handoff(thread_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS usage_record (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT,
        input_tokens INTEGER NOT NULL DEFAULT 0,
        cache_read_tokens INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        reasoning_tokens INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        cost_usd REAL,
        cost_source TEXT NOT NULL DEFAULT 'unknown',
        price_catalog_version TEXT,
        confirmed INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_run ON usage_record(run_id);
    CREATE INDEX IF NOT EXISTS idx_usage_thread ON usage_record(thread_id);

    CREATE TABLE IF NOT EXISTS rating (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL,
        run_id TEXT,
        handoff_id TEXT,
        provider TEXT NOT NULL,
        satisfaction TEXT,
        handoff_quality TEXT,
        rescue INTEGER NOT NULL DEFAULT 0,
        note TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_rating_run ON rating(run_id) WHERE run_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_rating_handoff ON rating(handoff_id) WHERE handoff_id IS NOT NULL;

    CREATE TABLE IF NOT EXISTS price_entry (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        input_per_mtok REAL NOT NULL,
        output_per_mtok REAL NOT NULL,
        cache_read_per_mtok REAL NOT NULL,
        cache_write_per_mtok REAL NOT NULL,
        source TEXT NOT NULL,
        effective_date TEXT NOT NULL,
        catalog_version TEXT NOT NULL,
        UNIQUE(provider, model, catalog_version)
    );

    CREATE TABLE IF NOT EXISTS app_setting (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS cli_verification (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        cli_version TEXT NOT NULL,
        checked_at REAL NOT NULL,
        capability TEXT NOT NULL,
        result TEXT NOT NULL,
        detail TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_cli_verif ON cli_verification(provider, cli_version);
    """
}
