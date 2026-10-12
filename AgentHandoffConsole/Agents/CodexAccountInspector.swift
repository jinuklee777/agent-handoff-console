import Foundation

/// `CODEX_HOME` 하나를 들여다보고 로그인돼 있는지 알아낸다. 누구 계정인지(이메일 · 플랜)는 CLI 에게 묻는다.
///
/// **읽기 전용이다.** 앱은 `auth.json` 을 쓰지도, 복사하지도, 어디로도 보내지도 않는다.
/// 토큰은 풀지 않는다 — 자격 정보가 있는지와 평범한 필드(`auth_mode` · `tokens.account_id`)만 본다. 이메일 · 플랜은
/// 한도를 읽을 때 같은 app-server 에 `account/read` 로 묻는다 (`parseAccountRead` → `CodexAccountService.applyAccountRead`).
/// 예전에는 `id_token`(JWT)의 페이로드를 풀어 읽었는데, 공개 형식이 아닌 파일에 기대고 토큰을 만지는 코드로 보여 뺐다 (2026-10-08).
///
/// 로그인 여부는 네트워크 · 프로세스 없이 파일로 본다 — 시작 점검표가 5초마다 부르는 곳이 있다.
/// 검증 환경: codex-cli 0.153.4 (2026-09-10). `auth.json` 은
/// `{ auth_mode, OPENAI_API_KEY, tokens: { id_token, access_token, refresh_token, account_id }, last_refresh }`.
enum CodexAccountInspector {

    /// 한 홈에서 읽어낸 결과. 실패는 실패로 남기고 로그인 안 됨과 섞지 않는다.
    struct Identity: Sendable, Equatable {
        var status: CodexAuthStatus = .notLoggedIn
        /// ChatGPT 로그인인가 (`tokens.access_token` 이 있다). API 키 로그인이면 false — 이메일 · 플랜이 없다.
        var usesChatGPT = false
        /// `tokens.account_id` — 토큰이 아니라 평범한 필드다. 다른 계정으로 다시 로그인했는지 알아보는 데 쓴다.
        var chatgptAccountID: String?
        var authMode: String?
        var note: String?
    }

    /// `account/read` 의 답 (app-server, codex-cli 0.160.1 실측 2026-10-07 — `docs/CLI프로토콜.md` 의 "계정 조회").
    /// ChatGPT 로그인이면 `{account: {type: "chatgpt", email, planType}, requiresOpenaiAuth, workspaceRouting: {chatgptAccountId, …}}`,
    /// 로그인하지 않았으면 `{account: null, …}`. 로그인된 계정은 app-server 가 시작할 때 `chatgpt.com` 에서 받아 오는 정보가 있어야
    /// 답한다 — 네트워크가 없으면 오류(`workspace routing discovery failed`)라 이 형식으로 오지 않는다.
    struct AccountRead: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case chatgpt
            case apiKey
            case loggedOut
            case other(String)
        }
        var kind: Kind
        var email: String?
        var planType: String?
        var chatgptAccountID: String?
    }

    /// `account/read` 의 `result` 를 푼다. 모르는 형식이면 nil (지난 값을 그대로 둔다).
    static func parseAccountRead(_ result: [String: Any]) -> AccountRead? {
        func text(_ value: Any?) -> String? {
            guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        let routingID = text((result["workspaceRouting"] as? [String: Any])?["chatgptAccountId"])
        guard let account = result["account"] as? [String: Any] else {
            return result["account"] is NSNull ? AccountRead(kind: .loggedOut) : nil
        }
        switch account["type"] as? String {
        case "chatgpt":
            return AccountRead(kind: .chatgpt, email: text(account["email"]), planType: text(account["planType"]),
                               chatgptAccountID: routingID)
        case "apiKey":
            return AccountRead(kind: .apiKey)
        case let type?:
            return AccountRead(kind: .other(type))
        case nil:
            return nil
        }
    }

    /// CLI 가 아무 설정 없이 쓰는 홈. `CODEX_HOME` 이 이미 설정돼 있으면 그 값을 따른다.
    static func defaultHomePath(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String {
        if let custom = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    static func authFileURL(home: String) -> URL {
        URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
            .appendingPathComponent("auth.json")
    }

    /// 홈 하나의 로그인 상태를 읽는다. CLI 를 실행하지 않는다.
    static func inspect(home: String) -> Identity {
        var identity = Identity()
        let url = authFileURL(home: home)

        guard FileManager.default.fileExists(atPath: url.path) else {
            identity.status = .notLoggedIn
            identity.note = "auth.json 이 없습니다. 이 계정 폴더로 아직 로그인하지 않았습니다."
            return identity
        }
        guard let data = try? Data(contentsOf: url) else {
            identity.status = .unreadable
            identity.note = "auth.json 을 읽지 못했습니다 (권한 또는 파일 오류)."
            return identity
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            identity.status = .unreadable
            identity.note = "auth.json 의 형식을 해석하지 못했습니다."
            return identity
        }

        identity.authMode = root["auth_mode"] as? String
        let tokens = root["tokens"] as? [String: Any]
        identity.chatgptAccountID = tokens?["account_id"] as? String

        let hasChatGPTToken = (tokens?["access_token"] as? String)?.isEmpty == false
        let hasAPIKey = (root["OPENAI_API_KEY"] as? String)?.isEmpty == false

        guard hasChatGPTToken || hasAPIKey else {
            identity.status = .unreadable
            identity.note = "auth.json 에 사용할 수 있는 자격 정보가 없습니다."
            return identity
        }
        identity.status = .loggedIn

        identity.usesChatGPT = hasChatGPTToken
        if hasAPIKey && !hasChatGPTToken {
            identity.note = "API 키 로그인입니다. 구독 한도가 아니라 API 사용량으로 청구됩니다."
        }
        return identity
    }

    /// 새 계정 홈으로 쓸 수 있는지 확인한다. 이미 등록된 홈과 겹치는지는 호출자가 본다.
    enum HomeCheck: Equatable {
        case usable(loggedIn: Bool)
        case notADirectory
        case notWritable

        var message: String {
            switch self {
            case .usable(let loggedIn):
                return loggedIn
                    ? "이미 로그인된 계정 폴더입니다."
                    : "빈 폴더입니다. 터미널에서 이 폴더로 로그인해야 쓸 수 있습니다."
            case .notADirectory: return "폴더가 아닙니다."
            case .notWritable: return "쓸 수 없는 폴더입니다. Codex CLI 가 이 폴더에 상태를 기록해야 합니다."
            }
        }
    }

    static func checkHome(_ path: String) -> HomeCheck {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
        if exists && !isDirectory.boolValue { return .notADirectory }
        if exists && !FileManager.default.isWritableFile(atPath: expanded) { return .notWritable }
        return .usable(loggedIn: inspect(home: expanded).status == .loggedIn)
    }

    /// 사용자가 터미널에서 그대로 실행할 로그인 명령.
    /// 앱이 로그인 절차를 대신하지 않는다 — 토큰을 앱이 만지지 않기 위해서다.
    /// CLI 가 아무 설정 없이 쓰는 홈(`~/.codex`, `CODEX_HOME` 없음)이면 `codex login` 만 — 첫 사용자에게 필요 없는 환경 변수와
    /// 개인 경로가 붙어 낯설었다 (cap-20). 추가 계정은 그 홈에 로그인되게 `CODEX_HOME=…` 을 붙인다.
    static func loginCommand(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        isCLIDefaultHome(home, environment: environment) ? "codex login" : "CODEX_HOME=\(shellQuoted(home)) codex login"
    }

    static func statusCommand(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        isCLIDefaultHome(home, environment: environment)
            ? "codex login status" : "CODEX_HOME=\(shellQuoted(home)) codex login status"
    }

    /// 이 홈이 CLI 의 기본 홈(`~/.codex`)이고 `CODEX_HOME` 을 따로 정하지 않았는가 — 그러면 명령에 홈을 붙이지 않아도 같은 곳이다.
    static func isCLIDefaultHome(_ home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let custom = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard custom.isEmpty else { return false }
        func normalized(_ path: String) -> String {
            var p = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p
        }
        return normalized(home) == normalized((NSHomeDirectory() as NSString).appendingPathComponent(".codex"))
    }

    static func shellQuoted(_ path: String) -> String {
        guard path.contains(where: { " \t\"'$`\\!*?()[]{}|;&<>#~".contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
