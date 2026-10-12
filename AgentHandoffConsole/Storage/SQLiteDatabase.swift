import Foundation
import SQLite3

/// sqlite3 의 C 문자열 수명 처리를 위한 상수.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String, String)
    case stepFailed(String, String)
    case migrationFailed(Int, String)
    case notOpen

    var errorDescription: String? {
        switch self {
        case .migrationFailed(let version, let m): return "스키마 v\(version) 마이그레이션 실패: \(m)"
        case .openFailed(let m): return "데이터베이스 열기 실패: \(m)"
        case .prepareFailed(let sql, let m): return "SQL 준비 실패: \(m)\n\(sql)"
        case .stepFailed(let sql, let m): return "SQL 실행 실패: \(m)\n\(sql)"
        case .notOpen: return "데이터베이스가 열려 있지 않습니다."
        }
    }
}

/// SQLite 값 바인딩 타입.
enum SQLValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    static func bool(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
    static func date(_ d: Date?) -> SQLValue {
        guard let d else { return .null }
        return .double(d.timeIntervalSince1970)
    }
    static func optText(_ s: String?) -> SQLValue {
        guard let s else { return .null }
        return .text(s)
    }
    static func optInt(_ i: Int?) -> SQLValue {
        guard let i else { return .null }
        return .int(Int64(i))
    }
    static func optDouble(_ d: Double?) -> SQLValue {
        guard let d else { return .null }
        return .double(d)
    }
}

/// 한 행. 컬럼 이름으로 접근한다.
struct SQLRow: Sendable {
    private let values: [String: SQLValue]

    init(values: [String: SQLValue]) { self.values = values }

    func int(_ key: String) -> Int64? {
        if case .int(let v)? = values[key] { return v }
        if case .double(let v)? = values[key] { return Int64(v) }
        return nil
    }
    func intValue(_ key: String, default def: Int = 0) -> Int { Int(int(key) ?? Int64(def)) }
    func int64Value(_ key: String, default def: Int64 = 0) -> Int64 { int(key) ?? def }
    func double(_ key: String) -> Double? {
        if case .double(let v)? = values[key] { return v }
        if case .int(let v)? = values[key] { return Double(v) }
        return nil
    }
    func text(_ key: String) -> String? {
        if case .text(let v)? = values[key] { return v }
        return nil
    }
    func textValue(_ key: String, default def: String = "") -> String { text(key) ?? def }
    func bool(_ key: String, default def: Bool = false) -> Bool {
        guard let v = int(key) else { return def }
        return v != 0
    }
    func date(_ key: String) -> Date? {
        guard let v = double(key) else { return nil }
        return Date(timeIntervalSince1970: v)
    }
    func dateValue(_ key: String) -> Date { date(key) ?? Date(timeIntervalSince1970: 0) }
}

/// 스트림 파싱·DB 작업이 메인 스레드를 막지 않도록 actor 로 격리한다.
actor SQLiteDatabase {
    private var handle: OpaquePointer?
    let path: URL

    init(path: URL) {
        self.path = path
    }

    func open() throws {
        guard handle == nil else { return }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "코드 \(rc)"
            sqlite3_close_v2(db)
            throw SQLiteError.openFailed(msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA synchronous=NORMAL;")
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func errorMessage() -> String {
        guard let handle else { return "핸들 없음" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// 결과를 반환하지 않는 SQL 실행 (여러 문장 가능).
    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError.notOpen }
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(errPtr)
            throw SQLiteError.stepFailed(sql, msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        guard let handle else { throw SQLiteError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(sql, errorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.stepFailed(sql, errorMessage())
        }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        guard let handle else { throw SQLiteError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(sql, errorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)

        let columnCount = Int(sqlite3_column_count(stmt))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for i in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(stmt, Int32(i))))
        }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError.stepFailed(sql, errorMessage())
            }
            var values: [String: SQLValue] = [:]
            for i in 0..<columnCount {
                let idx = Int32(i)
                switch sqlite3_column_type(stmt, idx) {
                case SQLITE_INTEGER: values[names[i]] = .int(sqlite3_column_int64(stmt, idx))
                case SQLITE_FLOAT:   values[names[i]] = .double(sqlite3_column_double(stmt, idx))
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, idx) {
                        values[names[i]] = .text(String(cString: c))
                    } else {
                        values[names[i]] = .null
                    }
                default: values[names[i]] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    /// 여러 문장을 하나의 트랜잭션으로 적용한다.
    func transaction(_ statements: [(String, [SQLValue])]) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            for (sql, params) in statements {
                try run(sql, params)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLValue]) {
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null:            sqlite3_bind_null(stmt, idx)
            case .int(let v):      sqlite3_bind_int64(stmt, idx, v)
            case .double(let v):   sqlite3_bind_double(stmt, idx, v)
            case .text(let v):     sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
        }
    }

    // MARK: 마이그레이션 지원

    func userVersion() throws -> Int {
        let rows = try query("PRAGMA user_version;")
        return rows.first?.intValue("user_version") ?? 0
    }

    /// 마이그레이션 한 단계를 원자적으로 적용한다. 단계 SQL 과 `user_version` 기록이 한 트랜잭션이라,
    /// 중간에 실패하면 스키마와 버전이 그대로 남고 고친 뒤 다시 실행할 수 있다.
    /// 액터 호출 하나로 끝나므로 BEGIN 과 COMMIT 사이에 다른 호출이 끼어들지 않는다.
    ///
    /// `foreignKeysOff` 는 테이블을 다시 만드는 단계용이다. `PRAGMA foreign_keys` 는 트랜잭션 안에서
    /// 무시되므로 바깥에서 끄고, 커밋 전에 위반을 검사하고, 성공 · 실패와 무관하게 다시 켠다.
    func applyMigration(sql: String, version: Int, foreignKeysOff: Bool) throws {
        if foreignKeysOff { try execute("PRAGMA foreign_keys=OFF;") }
        var failure: Error?
        do {
            try execute("BEGIN IMMEDIATE;")
            try execute(sql)
            if foreignKeysOff {
                let violations = try query("PRAGMA foreign_key_check;").count
                if violations > 0 {
                    throw SQLiteError.migrationFailed(version, "외래 키 위반 \(violations)건")
                }
            }
            try execute("PRAGMA user_version = \(version);")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            failure = error
        }
        if foreignKeysOff {
            // 연결을 열 때 켠 설정이 마이그레이션 뒤에도 유지돼야 한다. 복원을 확인하지 못하면 다음 단계로 가지 않는다.
            let restored = (try? execute("PRAGMA foreign_keys=ON;")) != nil
                && (try? query("PRAGMA foreign_keys;").first?.intValue("foreign_keys")) == 1
            if !restored && failure == nil {
                failure = SQLiteError.migrationFailed(version, "foreign_keys 를 다시 켜지 못했습니다")
            }
        }
        if let failure { throw failure }
    }
}
