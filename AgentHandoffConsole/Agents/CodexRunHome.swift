import Darwin
import Foundation

/// 대화의 Codex 세션을 그 기록이 있는 `CODEX_HOME`(기록 폴더)과 **다른 계정**으로 이어 갈 때, 그 실행 하나만의 `CODEX_HOME` (실행 폴더).
///
/// Codex 는 세션 기록(`sessions/` · SQLite)과 로그인(`auth.json`)을 같은 홈에 둔다. 실행 폴더는 실행 계정의 홈을 그대로 비추되(항목마다
/// 심볼릭 링크 — `auth.json` · `config.toml` · 스킬 · 훅 …), 기록 항목(`recordEntries`)만 기록 폴더로 링크하고 SQLite 는
/// `CODEX_SQLITE_HOME` 으로 기록 폴더를 직접 가리킨다. 그 실행은 실행 계정으로 로그인한 채 기록 폴더의 세션을 재개하고, 새 기록은 기록
/// 폴더에 쌓인다 — 인계가 아니다. 실측 (codex-cli 0.162.0, 실제 두 계정 — `inttest accountswitch`):
/// - `auth.json` 은 사본이 아니라 링크다 — 토큰 갱신이 링크를 남긴 채 계정 폴더의 파일에 써지고(refresh token 은 한 번만 쓰인다),
///   같은 계정 프로세스끼리는 갱신 전에 디스크를 다시 읽어 서로 건너뛴다. 사본을 주면 그 계정의 로그인이 풀릴 수 있다.
/// - 잠금 폴더 `thread-writer-locks` 를 기록 폴더와 나눠 써야 같은 스레드에 두 프로세스가 함께 쓰지 못한다.
/// - 링크 대상은 미리 만들어 둔다 — 없는 대상의 링크는 실행 폴더에 따로 생긴다.
/// - 인증을 파일이 아닌 곳(키체인 등)에 두는 계정은 이 방식으로 로그인을 옮길 수 없다 (`usesFileCredentials`).
/// 실행 폴더에는 링크만 있다 — 토큰 · 기록을 복사하지 않는다. 실행이 끝나면 지우고(`Prepared.remove`), 앱이 비정상으로 끝나 남은 것은
/// 다음 시작에 지운다 (`removeStale`).
enum CodexRunHome {
    /// 기록 폴더로 링크하는 항목 (나머지는 실행 계정의 홈으로).
    static let recordEntries = ["sessions", "archived_sessions", "thread-writer-locks", "session_index.jsonl"]
    /// 그중 폴더인 것 — 기록 폴더에 없으면 만들어 둔다.
    static let recordDirectories: Set<String> = ["sessions", "archived_sessions", "thread-writer-locks"]

    /// 실행 폴더들을 두는 곳 (사용자 임시 폴더 아래). 시험은 바꾼다.
    nonisolated(unsafe) static var baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ahc-codex-runs", isDirectory: true)

    enum Failure: Error, LocalizedError, Equatable {
        /// 기록 폴더가 없다.
        case recordHomeMissing(String)
        /// 실행 계정의 홈이 없다.
        case accountHomeMissing(String)
        /// 실행 계정이 인증을 파일이 아닌 곳에 둔다 — 다른 폴더의 세션으로 로그인을 옮길 수 없다.
        case nonFileCredentials(String)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .recordHomeMissing(let path): return "이 대화의 Codex 세션 기록 폴더를 찾지 못했습니다: \(path)"
            case .accountHomeMissing(let path): return "Codex 계정 폴더를 찾지 못했습니다: \(path)"
            case .nonFileCredentials(let label):
                return "\(label) 계정은 Codex 로그인을 파일(auth.json)이 아닌 곳(키체인 등)에 두어, 다른 계정이 시작한 이 대화의 세션을 "
                    + "이어 갈 수 없습니다 — 그 계정의 config.toml 에서 cli_auth_credentials_store 를 \"file\" 로 두고 다시 로그인하거나, "
                    + "이 세션을 시작한 계정으로 보내세요."
            case .io(let message): return "Codex 실행 폴더를 만들지 못했습니다: \(message)"
            }
        }
    }

    /// 준비한 실행 폴더.
    struct Prepared: Sendable {
        /// 실행에 넘길 `CODEX_HOME`.
        let home: String
        /// 기록 폴더 (`CODEX_SQLITE_HOME`).
        let recordHome: String
        /// 자식 환경에 덧씌울 값.
        var environment: [String: String] { ["CODEX_HOME": home, "CODEX_SQLITE_HOME": recordHome] }

        /// 실행 폴더를 지운다. 링크는 링크만 지운다 (가리키는 계정 · 기록 폴더는 그대로). 실행 중에 실행 폴더에 따로 생긴 것
        /// (캐시 · 셸 스냅샷)은 함께 지운다.
        func remove() {
            CodexRunHome.removeRunDirectory(home)
        }
    }

    /// 경로 비교용 — `~` 를 풀고 표준화한 뒤, 있는 데까지의 경로를 `realpath` 로 푼다 (`/tmp` ↔ `/private/tmp` · 끝의 `/` · 아직 없는
    /// 폴더도 있는 위 폴더까지는 푼다).
    static func normalized(_ path: String) -> String {
        let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        var existing = expanded
        var tail: [String] = []
        while existing.count > 1, !FileManager.default.fileExists(atPath: existing) {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return expanded }
        defer { free(resolved) }
        return tail.reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// 기록 폴더가 실행 계정의 홈과 같은 폴더인가 — 같으면 실행 폴더 없이 그 홈을 그대로 쓴다 (지금까지와 같은 실행).
    static func sameHome(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    /// 그 홈의 계정이 로그인을 파일(`auth.json`)에 두는가 — `config.toml` 의 `cli_auth_credentials_store` 가 없거나 file 일 때.
    static func usesFileCredentials(accountHome: String) -> Bool {
        let config = (accountHome as NSString).expandingTildeInPath + "/config.toml"
        return !CodexLoginJudge.usesNonFileStore(configToml: try? String(contentsOfFile: config, encoding: .utf8))
    }

    /// 실행 폴더를 만든다. 기록 폴더 · 실행 계정의 홈이 있어야 한다. 기록 폴더에 없는 기록 항목(폴더 · 빈 `session_index.jsonl`)은
    /// 먼저 만든다 — 링크 대상이 없으면 Codex 가 실행 폴더에 따로 만들어, 그 기록이 실행이 끝날 때 함께 사라진다.
    static func prepare(recordHome: String, accountHome: String, accountLabel: String, runID: String) throws -> Prepared {
        let fm = FileManager.default
        let record = (recordHome as NSString).expandingTildeInPath
        let account = (accountHome as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: record, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.recordHomeMissing(record)
        }
        guard fm.fileExists(atPath: account, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.accountHomeMissing(account)
        }
        guard usesFileCredentials(accountHome: account) else { throw Failure.nonFileCredentials(accountLabel) }
        do {
            for entry in recordEntries {
                let path = (record as NSString).appendingPathComponent(entry)
                guard !fm.fileExists(atPath: path) else { continue }
                if recordDirectories.contains(entry) {
                    try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                } else {
                    fm.createFile(atPath: path, contents: Data())
                }
            }
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            // 이름에 앱의 PID 를 넣는다 — 다음 시작이 죽은 앱의 것만 지운다 (`removeStale`, 다른 빌드가 함께 돌 수 있다).
            let home = baseDirectory.appendingPathComponent("\(getpid())-\(runID)", isDirectory: true).path
            if fm.fileExists(atPath: home) { removeRunDirectory(home) }
            try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
            let skipped = Set(recordEntries)
            for entry in try fm.contentsOfDirectory(atPath: account) where !skipped.contains(entry) && !entry.contains(".sqlite") {
                try fm.createSymbolicLink(atPath: (home as NSString).appendingPathComponent(entry),
                                          withDestinationPath: (account as NSString).appendingPathComponent(entry))
            }
            for entry in recordEntries {
                try fm.createSymbolicLink(atPath: (home as NSString).appendingPathComponent(entry),
                                          withDestinationPath: (record as NSString).appendingPathComponent(entry))
            }
            return Prepared(home: home, recordHome: record)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.io(error.localizedDescription)
        }
    }

    /// 앱을 켤 때: 끝난 앱(PID 가 살아 있지 않은)의 실행 폴더를 지운다. 이 앱이나 함께 도는 다른 빌드의 것은 남긴다.
    static func removeStale() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: baseDirectory.path) else { return }
        let me = getpid()
        for entry in entries {
            guard let pid = Int32(entry.split(separator: "-").first ?? ""), pid != me else { continue }
            // 살아 있는 프로세스면 (권한이 없어도 — EPERM) 남긴다.
            if kill(pid, 0) == 0 || errno == EPERM { continue }
            removeRunDirectory(baseDirectory.appendingPathComponent(entry).path)
        }
    }

    /// 실행 폴더 하나를 지운다 — 링크는 링크만 (`unlink`), 실행 폴더 안에 따로 생긴 것은 통째로.
    static func removeRunDirectory(_ path: String) {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
            let item = (path as NSString).appendingPathComponent(entry)
            if (try? fm.destinationOfSymbolicLink(atPath: item)) != nil {
                unlink(item)
            } else {
                try? fm.removeItem(atPath: item)
            }
        }
        try? fm.removeItem(atPath: path)
    }
}
