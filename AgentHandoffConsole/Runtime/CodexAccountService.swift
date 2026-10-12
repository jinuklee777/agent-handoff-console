import Foundation

/// Codex 계정(= `CODEX_HOME` 디렉터리) 목록 관리.
///
/// 이 서비스가 하는 일과 하지 않는 일을 분명히 해 둔다.
/// - **한다**: 홈 경로를 등록/해제하고, 각 홈의 `auth.json` 으로 로그인 여부를 보고, 한도를 읽을 때 CLI 가 알려 준 계정
///   (`account/read` — 이메일 · 플랜)을 보여준다. 토큰은 풀지 않는다.
/// - **하지 않는다**: 로그인·로그아웃, 토큰 복사, 홈 폴더 생성 외의 파일 변경, 계정 자동 전환.
///   로그인은 사용자가 터미널에서 직접 한다 (앱이 토큰을 만지지 않기 위해서다).
@MainActor
@Observable
final class CodexAccountService {

    enum AccountError: LocalizedError {
        case duplicateHome(String)
        case unusableHome(String)
        case cannotRemoveDefault
        case createFailed(String)

        var errorDescription: String? {
            switch self {
            case .duplicateHome(let label):
                return "이미 등록된 계정 폴더입니다: \(label)"
            case .unusableHome(let reason):
                return "이 폴더는 Codex 계정 폴더(CODEX_HOME)로 쓸 수 없습니다: \(reason)"
            case .cannotRemoveDefault:
                return "기본 계정(~/.codex)은 등록을 해제할 수 없습니다."
            case .createFailed(let reason):
                return "폴더를 만들지 못했습니다: \(reason)"
            }
        }
    }

    private(set) var accounts: [CodexAccount] = []
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    // MARK: - 조회

    func account(_ id: String) -> CodexAccount? {
        accounts.first { $0.id == id }
    }

    /// 스레드가 가리키는 계정이 사라졌으면 기본 계정으로 되돌린다.
    /// 없는 계정으로 조용히 실행하지 않기 위해 항상 실재하는 계정을 돌려준다.
    func accountOrDefault(_ id: String) -> CodexAccount {
        account(id) ?? defaultAccount
    }

    var defaultAccount: CodexAccount {
        account(CodexAccount.defaultID)
            ?? accounts.first
            ?? CodexAccount(id: CodexAccount.defaultID, label: "기본 계정",
                            homePath: CodexAccountInspector.defaultHomePath())
    }

    func ref(_ id: String) -> CodexAccountRef {
        CodexAccountRef(accountOrDefault(id))
    }

    var refs: [CodexAccountRef] { accounts.map { CodexAccountRef($0) } }

    /// 계정이 둘 이상일 때만 계정 선택 UI 를 보여준다.
    var hasMultiple: Bool { accounts.count > 1 }

    // MARK: - 적재

    /// 기본 계정 행을 보장하고 목록을 읽는다. 식별 정보도 함께 갱신한다.
    func load() async {
        var stored = (try? await store.codexAccounts()) ?? []

        let resolvedDefault = CodexAccountInspector.defaultHomePath()
        if let index = stored.firstIndex(where: { $0.id == CodexAccount.defaultID }) {
            // 셸의 CODEX_HOME 이 바뀌면 기본 홈도 따라간다. 다른 계정과 겹치면 그대로 둔다.
            let taken = stored.contains { $0.id != CodexAccount.defaultID
                                          && Self.samePath($0.homePath, resolvedDefault) }
            if !taken, !Self.samePath(stored[index].homePath, resolvedDefault) {
                stored[index].homePath = resolvedDefault
                try? await store.upsertCodexAccount(stored[index])
            }
        } else {
            let account = CodexAccount(id: CodexAccount.defaultID, label: "기본 계정",
                                       homePath: resolvedDefault, sortOrder: 0)
            try? await store.upsertCodexAccount(account)
            stored.insert(account, at: 0)
        }

        accounts = stored.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        await refreshAllIdentities()
    }

    // MARK: - 식별 (auth.json 읽기 · account/read)

    func refreshAllIdentities() async {
        for account in accounts {
            await refreshIdentity(account.id)
        }
    }

    /// `auth.json` 으로 로그인 여부를 갱신한다. CLI 를 실행하지 않고 네트워크도 쓰지 않는다 (시작 점검표가 5초마다 부른다).
    /// 이메일 · 플랜은 여기서 알 수 없다 — 한도를 읽을 때의 `account/read`(`applyAccountRead`)가 채운 값을 그대로 두고,
    /// 로그인이 풀렸거나 · API 키 로그인이거나 · 다른 계정으로 다시 로그인했을 때만 지운다.
    func refreshIdentity(_ id: String) async {
        guard var account = account(id) else { return }
        let identity = CodexAccountInspector.inspect(home: account.homePath)
        account.authStatus = identity.status
        account.authMode = identity.authMode
        account.identityNote = identity.note
        // id_token 을 풀지 않으므로 만료 시각은 더 모른다 (예전에 저장한 값도 지운다 — 지나도 로그인은 그대로였다).
        account.tokenExpiresAt = nil
        if identity.status != .loggedIn || !identity.usesChatGPT {
            account.email = nil
            account.planType = nil
            account.chatgptAccountID = identity.chatgptAccountID
        } else if let fileID = identity.chatgptAccountID {
            if let known = account.chatgptAccountID, known != fileID {
                // 다른 계정으로 다시 로그인했다 — 이메일 · 플랜은 다음 한도 조회의 `account/read` 가 채운다.
                account.email = nil
                account.planType = nil
            }
            account.chatgptAccountID = fileID
        }
        account.identityCheckedAt = Date()
        try? await store.upsertCodexAccount(account)
        replace(account)
    }

    /// 한도를 읽을 때 같은 app-server 에 물은 `account/read`(`LimitsFetcher.fetchCodexWithAccount`)를 반영한다 — 이메일 · 플랜 ·
    /// 계정 ID 만. 로그인 여부는 바꾸지 않는다 (`auth.json` 이 정한다). 답을 받지 못하면(네트워크 없음 · 옛 CLI) 불리지 않아
    /// 지난 값이 남는다.
    func applyAccountRead(_ id: String, _ read: CodexAccountInspector.AccountRead) async {
        guard var account = account(id), account.authStatus == .loggedIn, read.kind == .chatgpt else { return }
        // 그 사이 이 폴더에서 다른 계정으로 다시 로그인했으면 앞서 띄운 프로세스의 답이다 — 쓰지 않는다.
        if let fileID = account.chatgptAccountID, let readID = read.chatgptAccountID, fileID != readID { return }
        let before = account
        if let email = read.email { account.email = email }
        if let plan = read.planType { account.planType = plan }
        if let readID = read.chatgptAccountID { account.chatgptAccountID = readID }
        guard account != before else { return }
        try? await store.upsertCodexAccount(account)
        replace(account)
    }

    // MARK: - 편집

    /// 새 계정 홈을 등록한다. 폴더가 없으면 만들고, 로그인은 사용자가 직접 한다.
    @discardableResult
    func add(homePath: String, label: String) async throws -> CodexAccount {
        let expanded = (homePath as NSString).expandingTildeInPath
        if let existing = accounts.first(where: { Self.samePath($0.homePath, expanded) }) {
            throw AccountError.duplicateHome(existing.label)
        }
        if !FileManager.default.fileExists(atPath: expanded) {
            do {
                try FileManager.default.createDirectory(
                    atPath: expanded, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw AccountError.createFailed(error.localizedDescription)
            }
        }
        switch CodexAccountInspector.checkHome(expanded) {
        case .usable: break
        case let other: throw AccountError.unusableHome(other.message)
        }

        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var account = CodexAccount(
            label: trimmed.isEmpty ? (expanded as NSString).lastPathComponent : trimmed,
            homePath: expanded, sortOrder: accounts.count)
        try await store.upsertCodexAccount(account)
        accounts.append(account)
        await refreshIdentity(account.id)
        account = self.account(account.id) ?? account
        return account
    }

    func rename(_ id: String, to label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var account = account(id), !trimmed.isEmpty else { return }
        account.label = trimmed
        try? await store.upsertCodexAccount(account)
        replace(account)
    }

    /// 이 계정을 쓰도록 설정된 스레드 수. 등록 해제 전에 영향을 보여주기 위해 쓴다.
    func threadCount(using id: String) async -> Int {
        (try? await store.threadCount(usingCodexAccount: id)) ?? 0
    }

    /// 앱에서 등록만 해제한다. **홈 폴더와 로그인 상태는 그대로 둔다.**
    /// 이 계정을 쓰던 스레드는 기본 계정으로 되돌아가며, 세션 기록은 지우지 않는다.
    @discardableResult
    func remove(_ id: String) async throws -> Int {
        guard id != CodexAccount.defaultID else { throw AccountError.cannotRemoveDefault }
        let moved = (try? await store.reassignThreads(fromCodexAccount: id,
                                                      to: CodexAccount.defaultID)) ?? 0
        try await store.deleteCodexAccount(id: id)
        accounts.removeAll { $0.id == id }
        return moved
    }

    // MARK: - 보조

    #if DEBUG
    /// 화면 확인용 (`-preview.limits` 의 `login=`, AHC_OFFLINE=1): 메모리의 로그인 상태만 바꾼다 (홈 · DB 는 건드리지 않는다).
    func previewSetAuthStatus(_ id: String, _ status: CodexAuthStatus) {
        guard var account = account(id) else { return }
        account.authStatus = status
        account.identityCheckedAt = Date()
        replace(account)
    }
    #endif

    private func replace(_ account: CodexAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        func normalize(_ s: String) -> String {
            var p = ((s as NSString).expandingTildeInPath as NSString).standardizingPath
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p
        }
        return normalize(a) == normalize(b)
    }

    /// 새 계정 홈의 기본 제안 경로. `~/.codex` 를 건드리지 않도록 별도 폴더를 쓴다.
    static func suggestedHomePath(existing: [CodexAccount]) -> String {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".codex-accounts")
        var index = existing.count + 1
        while true {
            let candidate = (base as NSString).appendingPathComponent("account\(index)")
            if !existing.contains(where: { samePath($0.homePath, candidate) })
                && !FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            index += 1
        }
    }
}
