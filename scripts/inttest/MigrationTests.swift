import Foundation

// MARK: - 마이그레이션 실행기 (단계별 원자 적용 · 외래 키 전환 · 실패 복구)

/// `Migrations.migrate` 와 `SQLiteDatabase.applyMigration` 을 임시 DB 로 검증한다. 네트워크 · CLI 를 쓰지 않는다.
enum MigrationTests {

    static func run(_ t: TestKit) async {
        await t.group("마이그레이션 실행기")
        do {
            try await freshDatabase(t)
            try await upgradeFromV2(t)
            try await codexSessionPerConversation(t)
            try await upgradeFromLatest(t)
            try await failureInjection(t)
            try await foreignKeyViolation(t)
            try await nestedTransactionRule(t)
        } catch {
            await t.check("마이그레이션 검증 중 예외", false, "\(error)")
        }
    }

    // MARK: 도우미

    private static var latest: Int { Migrations.all.last?.version ?? 0 }

    private static func withDatabase(_ body: (SQLiteDatabase) async throws -> Void) async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-migration-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let db = SQLiteDatabase(path: url)
        try await db.open()
        try await body(db)
        await db.close()
    }

    private static func schema(_ db: SQLiteDatabase) async throws -> [String] {
        try await db.query("""
            SELECT type, name, sql FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name;
            """).map { "\($0.textValue("type"))|\($0.textValue("name"))|\($0.textValue("sql"))" }
    }

    private static func foreignKeys(_ db: SQLiteDatabase) async throws -> Int {
        try await db.query("PRAGMA foreign_keys;").first?.intValue("foreign_keys") ?? -1
    }

    private static func count(_ db: SQLiteDatabase, _ table: String) async throws -> Int {
        try await db.query("SELECT COUNT(*) AS c FROM \(table);").first?.intValue("c") ?? -1
    }

    /// 실행기를 고치기 전의 방식: v3 가 SQL 안에서 직접 foreign_keys 를 끄고 BEGIN/COMMIT 했고,
    /// 단계 SQL 과 user_version 기록이 별개 호출이었다. 기존 설치본은 이 방식으로 만들어졌다.
    private static func legacyMigrate(_ db: SQLiteDatabase) async throws {
        for step in Migrations.all {
            var sql = step.sql
            if step.version == 3 {
                sql = sql.replacingOccurrences(
                    of: "CREATE TABLE agent_session_v3 (",
                    with: "PRAGMA foreign_keys=off;\nBEGIN;\nCREATE TABLE agent_session_v3 (")
                sql = sql.replacingOccurrences(
                    of: "ALTER TABLE agent_session_v3 RENAME TO agent_session;",
                    with: "ALTER TABLE agent_session_v3 RENAME TO agent_session;\nCOMMIT;\nPRAGMA foreign_keys=on;")
            }
            try await db.execute(sql)
            try await db.execute("PRAGMA user_version = \(step.version);")
        }
    }

    private static let v2Rows = """
    INSERT INTO project(id,name,path,created_at) VALUES('p1','프로젝트','/tmp/x',1);
    INSERT INTO thread(id,project_id,title,created_at,updated_at,codex_model) VALUES('t1','p1','스레드',1,1,'gpt');
    INSERT INTO thread(id,project_id,title,created_at,updated_at) VALUES('t2','p1','둘째',1,1);
    INSERT INTO agent_session(id,thread_id,provider,cli_session_id,created_at,updated_at) VALUES('s1','t1','claude','c-1',1,1);
    INSERT INTO agent_session(id,thread_id,provider,cli_session_id,created_at,updated_at) VALUES('s2','t1','codex','x-1',1,1);
    INSERT INTO agent_session(id,thread_id,provider,cli_session_id,created_at,updated_at) VALUES('s3','t2','codex','x-2',1,1);
    INSERT INTO run(id,thread_id,session_id,provider,state,started_at) VALUES('r1','t1','s1','claude','completed',1);
    INSERT INTO run(id,thread_id,session_id,provider,state,started_at) VALUES('r2','t1','s2','codex','completed',1);
    INSERT INTO handoff(id,thread_id,from_provider,to_provider,base_seq,packet_version,draft_json,final_text,
                        delivery_state,local_token,created_at)
        VALUES('h1','t1','claude','codex',0,1,'{}','본문','sent','tok1',1);
    INSERT INTO model_option(id,provider,identifier,display_name,fetched_at) VALUES('m1','codex','gpt','GPT',1);
    """

    // MARK: 검증

    /// 빈 DB → 최신. 옛 방식으로 만든 DB(기존 설치본)와 스키마가 같아야 한다.
    private static func freshDatabase(_ t: TestKit) async throws {
        var legacySchema: [String] = []
        try await withDatabase { db in
            try await legacyMigrate(db)
            legacySchema = try await schema(db)
        }
        try await withDatabase { db in
            try await Migrations.migrate(db)
            await t.equal("빈 DB → 최신 버전", try await db.userVersion(), latest)
            let now = try await schema(db)
            await t.check("옛 방식으로 만든 DB 와 스키마 동일", now == legacySchema,
                          "차이 \(Set(now).symmetricDifference(Set(legacySchema)).count)개")
            await t.equal("v3 뒤 foreign_keys 복원", try await foreignKeys(db), 1)
            try await Migrations.migrate(db)
            await t.check("재적용해도 스키마 그대로", try await schema(db) == now)
        }
    }

    /// v2 DB(표본 행) → 최신. 테이블을 다시 만드는 v3 를 자료와 함께 지난다.
    private static func upgradeFromV2(_ t: TestKit) async throws {
        var freshSchema: [String] = []
        try await withDatabase { db in
            try await Migrations.migrate(db)
            freshSchema = try await schema(db)
        }
        try await withDatabase { db in
            try await Migrations.migrate(db, steps: Migrations.all.filter { $0.version <= 2 })
            await t.equal("v2 DB 준비", try await db.userVersion(), 2)
            try await db.execute(v2Rows)

            try await Migrations.migrate(db)
            await t.equal("v2 DB → 최신 버전", try await db.userVersion(), latest)
            await t.check("v2 에서 올린 스키마 = 빈 DB 에서 만든 스키마", try await schema(db) == freshSchema)

            let sessions = try await db.query("""
                SELECT id, provider, account_id, cli_session_id FROM agent_session
                WHERE NOT (provider = 'codex' AND account_id = '') ORDER BY id;
                """)
                .map { "\($0.textValue("id")) \($0.textValue("provider")) [\($0.textValue("account_id"))] \($0.textValue("cli_session_id"))" }
            await t.equal("세션 행 보존 · Codex 는 codex-default 로 연결", sessions,
                          ["s1 claude [] c-1", "s2 codex [codex-default] x-1", "s3 codex [codex-default] x-2"])
            let shared = try await db.query("""
                SELECT thread_id, cli_session_id, record_home FROM agent_session
                WHERE provider = 'codex' AND account_id = '' ORDER BY thread_id;
                """).map { "\($0.textValue("thread_id")) \($0.textValue("cli_session_id")) \($0.text("record_home") ?? "NULL")" }
            await t.equal("v10: 대화마다 Codex 세션 하나 (계정 목록에 없는 계정 → 기록 폴더 모름)", shared,
                          ["t1 x-1 NULL", "t2 x-2 NULL"])
            let runs = try await db.query("SELECT id, codex_account_id FROM run ORDER BY id;")
                .map { "\($0.textValue("id")) \($0.text("codex_account_id") ?? "NULL")" }
            await t.equal("실행 행의 계정 연결", runs, ["r1 NULL", "r2 codex-default"])
            let handoff = try await db.query("SELECT from_account_id, to_account_id FROM handoff WHERE id='h1';").first
            await t.equal("인계 행의 계정 연결",
                          "\(handoff?.textValue("from_account_id") ?? "?")→\(handoff?.textValue("to_account_id") ?? "?")",
                          "→codex-default")
            await t.equal("스레드 행 보존", try await count(db, "thread"), 2)
            await t.equal("모델 목록 캐시는 v3 에서 비운다", try await count(db, "model_option"), 0)

            await t.equal("foreign_keys 복원", try await foreignKeys(db), 1)
            await t.check("외래 키 위반 없음", try await db.query("PRAGMA foreign_key_check;").isEmpty)

            var duplicateRejected = false
            do {
                try await db.execute("""
                    INSERT INTO agent_session(id,thread_id,provider,account_id,created_at,updated_at)
                    VALUES('s9','t1','codex','codex-default',1,1);
                    """)
            } catch { duplicateRejected = true }
            await t.check("새 UNIQUE(thread_id, provider, account_id) 적용", duplicateRejected)
            try await db.execute("DELETE FROM thread WHERE id='t2';")
            await t.check("다시 만든 agent_session 의 ON DELETE CASCADE (v10 의 대화 칸도)",
                          try await db.query("SELECT id FROM agent_session WHERE thread_id='t2';").isEmpty)
        }
    }

    /// v10: 계정마다 갈라져 있던 Codex 세션 칸 → 대화의 칸 하나. 세션 ID 가 있는 칸을 먼저, 그다음 가장 최근 것 · 기록 폴더 = 그 계정의 홈.
    private static func codexSessionPerConversation(_ t: TestKit) async throws {
        try await withDatabase { db in
            try await Migrations.migrate(db, steps: Migrations.all.filter { $0.version <= 9 })
            await t.equal("v9 DB 준비", try await db.userVersion(), 9)
            try await db.execute("""
            INSERT INTO project(id,name,path,created_at) VALUES('p1','프로젝트','/tmp/x',1);
            INSERT INTO thread(id,project_id,title,created_at,updated_at) VALUES('t1','p1','둘 다 씀',1,1);
            INSERT INTO thread(id,project_id,title,created_at,updated_at) VALUES('t2','p1','최근 칸은 세션 없음',1,1);
            INSERT INTO thread(id,project_id,title,created_at,updated_at) VALUES('t3','p1','Claude 만',1,1);
            INSERT INTO thread(id,project_id,title,created_at,updated_at) VALUES('t4','p1','지운 계정',1,1);
            INSERT INTO codex_account(id,label,home_path,created_at) VALUES('codex-default','기본','/h/a',1);
            INSERT INTO codex_account(id,label,home_path,created_at) VALUES('acct-b','둘째','/h/b',1);
            INSERT INTO agent_session(id,thread_id,provider,account_id,cli_session_id,created_at,updated_at)
                VALUES('a1','t1','codex','codex-default','x-a',1,10);
            INSERT INTO agent_session(id,thread_id,provider,account_id,cli_session_id,created_at,updated_at)
                VALUES('b1','t1','codex','acct-b','x-b',1,20);
            INSERT INTO agent_session(id,thread_id,provider,account_id,cli_session_id,created_at,updated_at)
                VALUES('a2','t2','codex','codex-default','x-2a',1,5);
            INSERT INTO agent_session(id,thread_id,provider,account_id,cli_session_id,created_at,updated_at)
                VALUES('b2','t2','codex','acct-b',NULL,1,30);
            INSERT INTO agent_session(id,thread_id,provider,account_id,cli_session_id,created_at,updated_at)
                VALUES('c3','t3','claude','','c-3',1,1);
            INSERT INTO agent_session(id,thread_id,provider,account_id,cli_session_id,last_delivered_seq,resumable,created_at,updated_at)
                VALUES('g4','t4','codex','gone','x-4',7,0,1,1);
            """)
            try await Migrations.migrate(db)
            await t.equal("v9 → 최신", try await db.userVersion(), latest)
            let shared = try await db.query("""
                SELECT thread_id, cli_session_id, record_home, last_delivered_seq, resumable FROM agent_session
                WHERE provider = 'codex' AND account_id = '' ORDER BY thread_id;
                """).map {
                    "\($0.textValue("thread_id")) \($0.textValue("cli_session_id")) \($0.text("record_home") ?? "NULL") "
                        + "\($0.int64Value("last_delivered_seq")) \($0.bool("resumable", default: true))"
                }
            await t.equal("대화의 칸: 가장 최근에 쓴 칸(세션 ID 가 있는 것 먼저) · 그 계정의 홈 · 전달 지점 · 재개 여부", shared,
                          ["t1 x-b /h/b 0 true", "t2 x-2a /h/a 0 true", "t4 x-4 NULL 7 false"])
            await t.equal("옛 계정 칸은 그대로 남는다", try await count(db, "agent_session"), 6 + 3)
            await t.check("외래 키 위반 없음", try await db.query("PRAGMA foreign_key_check;").isEmpty)
        }
    }

    /// 최신 DB → 새 단계. 앞으로 추가할 마이그레이션이 지날 길이다.
    private static func upgradeFromLatest(_ t: TestKit) async throws {
        try await withDatabase { db in
            try await Migrations.migrate(db)
            try await db.execute("""
                INSERT INTO project(id,name,path,created_at) VALUES('p1','프로젝트','/tmp/x',1);
                INSERT INTO thread(id,project_id,title,created_at,updated_at) VALUES('t1','p1','스레드',1,1);
                """)
            let next = Migrations.Step(version: latest + 1, sql: """
                ALTER TABLE thread ADD COLUMN migration_probe TEXT;
                CREATE TABLE migration_probe_table (id TEXT PRIMARY KEY, thread_id TEXT REFERENCES thread(id));
                UPDATE thread SET migration_probe = 'ok';
                """)
            try await Migrations.migrate(db, steps: Migrations.all + [next])
            await t.equal("최신 DB → 새 단계 버전", try await db.userVersion(), latest + 1)
            await t.equal("기존 행 보존 · 새 컬럼 채움",
                          try await db.query("SELECT migration_probe FROM thread WHERE id='t1';").first?.text("migration_probe"),
                          "ok")
        }
    }

    /// 단계 중간에 실패하면 아무것도 남지 않고, 고친 뒤 다시 실행할 수 있어야 한다.
    /// (고치기 전에는 ADD COLUMN 이 남아 재실행이 duplicate column 으로 막혔다.)
    private static func failureInjection(_ t: TestKit) async throws {
        for foreignKeysOff in [false, true] {
            let label = foreignKeysOff ? "외래 키 끄는 단계" : "일반 단계"
            try await withDatabase { db in
                try await Migrations.migrate(db)
                let before = try await schema(db)
                let broken = Migrations.Step(version: latest + 1, sql: """
                    ALTER TABLE thread ADD COLUMN migration_probe TEXT;
                    CREATE TABLE migration_probe_table (id TEXT PRIMARY KEY);
                    INSERT INTO no_such_table VALUES (1);
                    """, foreignKeysOff: foreignKeysOff)
                var threw = false
                do { try await Migrations.migrate(db, steps: Migrations.all + [broken]) } catch { threw = true }
                await t.check("\(label) 실패: 오류 전파", threw)
                await t.equal("\(label) 실패: user_version 그대로", try await db.userVersion(), latest)
                await t.check("\(label) 실패: ADD COLUMN · CREATE TABLE 되돌림", try await schema(db) == before)
                await t.equal("\(label) 실패: foreign_keys 켜짐", try await foreignKeys(db), 1)

                let fixed = Migrations.Step(version: latest + 1,
                                            sql: "ALTER TABLE thread ADD COLUMN migration_probe TEXT;",
                                            foreignKeysOff: foreignKeysOff)
                try await Migrations.migrate(db, steps: Migrations.all + [fixed])
                await t.equal("\(label) 실패: 고친 뒤 재실행 성공", try await db.userVersion(), latest + 1)
            }
        }
    }

    /// 외래 키를 끄고 돈 단계가 위반을 남기면 커밋하지 않는다.
    private static func foreignKeyViolation(_ t: TestKit) async throws {
        try await withDatabase { db in
            try await Migrations.migrate(db)
            let orphan = Migrations.Step(version: latest + 1, sql: """
                INSERT INTO composer_draft(thread_id, text, revision, updated_at) VALUES('no-such-thread', '', 0, 1);
                """, foreignKeysOff: true)
            var message = ""
            do { try await Migrations.migrate(db, steps: Migrations.all + [orphan]) } catch {
                message = error.localizedDescription
            }
            await t.check("외래 키 위반 단계는 거부", message.contains("외래 키 위반"), message)
            await t.equal("외래 키 위반: 행이 남지 않음", try await count(db, "composer_draft"), 0)
            await t.equal("외래 키 위반: user_version 그대로", try await db.userVersion(), latest)
            await t.equal("외래 키 위반: foreign_keys 켜짐", try await foreignKeys(db), 1)
        }
    }

    /// 단계 SQL 에 BEGIN 을 쓰면 안 된다는 규칙. 어기면 깨끗하게 실패해야 한다.
    private static func nestedTransactionRule(_ t: TestKit) async throws {
        try await withDatabase { db in
            try await Migrations.migrate(db)
            let before = try await schema(db)
            let nested = Migrations.Step(version: latest + 1, sql: """
                CREATE TABLE migration_probe_table (id TEXT PRIMARY KEY);
                BEGIN;
                CREATE TABLE migration_probe_other (id TEXT PRIMARY KEY);
                COMMIT;
                """)
            var message = ""
            do { try await Migrations.migrate(db, steps: Migrations.all + [nested]) } catch {
                message = error.localizedDescription
            }
            await t.check("단계 SQL 안의 BEGIN 은 중첩 트랜잭션 오류", message.contains("within a transaction"), message)
            await t.check("중첩 트랜잭션 실패: 스키마 그대로", try await schema(db) == before)
            await t.equal("중첩 트랜잭션 실패: user_version 그대로", try await db.userVersion(), latest)
        }
    }
}
