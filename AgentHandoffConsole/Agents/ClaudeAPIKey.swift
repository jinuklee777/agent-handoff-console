import Foundation
import Security

/// Claude API 키 — Claude Console 조직에서 만든 키. Max · Team 플랜의 월 API 크레딧은 claude.ai 결제 설정에서 연결한 Console 조직으로
/// 들어오고, **그 조직의 API 키로 `claude -p` 를 실행할 때만** 크레딧에서 빠진다 (구독으로 로그인한 채 실행하면 구독 한도).
/// `claude -p` 는 환경에 `ANTHROPIC_API_KEY` 가 있으면 늘 그 키를 쓴다 — 그래서 모델 칩의 "API 크레딧으로 실행" 을 켠 대화의 Claude
/// 실행에만 이 키를 넣는다 (`environment(_:apiKey:)` ← `RunSession.makeAdapter`). 근거는 docs/CLI프로토콜.md 의 "API 키로 실행".
///
/// 키는 macOS 키체인에만 둔다 (설정 > 에이전트 > Claude Code 에서 넣는다 — 사용자 결정 2026-10-08). 앱은 키를 기록 · 인계 문서 ·
/// 로그에 남기지 않고 그 실행의 자식 프로세스 환경에만 넣는다. 화면은 끝 네 글자만 쓴다 (`masked` — 설정 `claude_api_key_hint`, 앱을 켤 때
/// 키체인을 읽지 않으려고). 키는 처음 실행에 쓸 때 한 번 읽어 메모리에 둔다 — 서명이 바뀐 빌드는 읽을 때마다 키체인 허락을 물을 수 있다.
enum ClaudeAPIKey {
    /// 키를 두는 곳. 앱은 키체인, 시험은 메모리 (`ClaudeAPIKeyMemoryStorage`) — 시험이 사용자의 키체인을 건드리지 않게.
    static var storage: ClaudeAPIKeyStorage = ClaudeAPIKeyKeychainStorage() {
        didSet { lock.withLock { cached = nil } }
    }

    private static let lock = UnfairLock()
    /// 한 번 읽은 키 (nil = 아직 읽지 않음, .some(nil) = 읽었는데 없음).
    private static var cached: String??

    static func load() -> String? {
        if let known = lock.withLock({ cached }) { return known }
        let value = storage.load().map(normalized).flatMap { $0.isEmpty ? nil : $0 }
        lock.withLock { cached = .some(value) }
        return value
    }

    /// 다듬은 키를 저장한다. 저장하지 못하면 false.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let value = normalized(key)
        guard problem(in: value) == nil, storage.save(value) else { return false }
        lock.withLock { cached = .some(value) }
        return true
    }

    static func delete() {
        storage.delete()
        lock.withLock { cached = .some(nil) }
    }

    /// 붙여 넣은 키의 앞뒤 빈칸 · 줄바꿈을 뗀다.
    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 저장하지 않는 까닭 (없으면 nil). Console 의 API 키는 `sk-ant-` 로 시작한다. `claude setup-token` 의 구독 토큰(`sk-ant-oat…`)과
    /// 관리자 키(`sk-ant-admin…`)는 모델 요청에 이 키로 쓸 수 없어 따로 말한다.
    static func problem(in key: String) -> String? {
        let value = normalized(key)
        if value.isEmpty { return "키를 붙여 넣으세요." }
        if value.contains(where: \.isWhitespace) { return "키 가운데에 빈칸이 있습니다 — 키 전체를 다시 복사해 붙여 넣으세요." }
        if value.hasPrefix("sk-ant-oat") {
            return "구독 토큰(claude setup-token)입니다. API 크레딧에는 Claude Console 에서 만든 API 키를 넣으세요."
        }
        if value.hasPrefix("sk-ant-admin") { return "관리자 키는 모델 요청에 쓸 수 없습니다. 일반 API 키를 넣으세요." }
        if !value.hasPrefix("sk-ant-") { return "Claude Console 의 API 키는 sk-ant- 로 시작합니다." }
        return nil
    }

    /// 화면에 보일 모양 — 앞머리와 끝 네 글자 ("sk-ant-…a1b2").
    static func masked(_ key: String) -> String {
        let value = normalized(key)
        return "sk-ant-…" + String(value.suffix(4))
    }

    /// 이 실행의 자식 환경. 키가 있으면 `ANTHROPIC_API_KEY` 로 넣고, CLI 가 그보다 먼저 쓰는 자격(클라우드 제공자 표시 ·
    /// `ANTHROPIC_AUTH_TOKEN`)은 뺀다 — 남겨 두면 키가 아니라 그것으로 실행돼 크레딧에서 빠지지 않는다 (인증 순서는 Claude Code 문서
    /// "Authentication precedence"). 키가 없으면 그대로 (구독 로그인 — 지금까지와 같다).
    static func environment(_ base: [String: String], apiKey: String?) -> [String: String] {
        guard let apiKey, !apiKey.isEmpty else { return base }
        var env = base
        for name in overridingVariables { env.removeValue(forKey: name) }
        env["ANTHROPIC_API_KEY"] = apiKey
        return env
    }

    /// `ANTHROPIC_API_KEY` 보다 앞 순위의 자격 (Claude Code 의 인증 순서 1 · 2).
    static let overridingVariables: [String] = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_AUTH_TOKEN",
    ]

    // MARK: 오류 글

    /// Console 조직의 크레딧이 떨어졌다는 글인가 — API 의 "Your credit balance is too low to access the Anthropic API…" ·
    /// Claude Code 의 "Credit balance too low · Add funds: …" (Claude Platform 문서 "When credits run out").
    static func isCreditExhausted(_ text: String?) -> Bool {
        guard let raw = text?.lowercased() else { return false }
        return raw.contains("credit balance is too low") || raw.contains("credit balance too low")
    }

    /// 키가 맞지 않다는 글인가 — API 의 `invalid x-api-key` · Claude Code 의 "Invalid API key".
    static func isInvalidKey(_ text: String?) -> Bool {
        guard let raw = text?.lowercased() else { return false }
        return raw.contains("invalid x-api-key") || raw.contains("invalid api key")
    }

    /// 오류 줄 아래에 붙일 할 일 한 줄 (해당 없으면 nil).
    static func errorNote(for text: String?) -> String? {
        if isCreditExhausted(text) {
            return "Claude Console 조직의 API 크레딧이 떨어졌습니다. 월 크레딧은 다음 결제일에 다시 들어오고, 그 전에는 구독으로 넘어가지 않습니다. "
                + "모델 칩에서 ‘API 크레딧으로 실행’ 을 끄면 구독 한도로 보냅니다."
        }
        if isInvalidKey(text) {
            return "Claude API 키가 맞지 않습니다. 설정 > 에이전트 > Claude Code 에서 키를 다시 넣거나, 모델 칩에서 ‘API 크레딧으로 실행’ 을 끄세요."
        }
        return nil
    }

    // MARK: 화면 글

    /// 모델 칩 팝오버 · 설정에 같이 쓰는 이름.
    static let toggleTitle = "API 크레딧으로 실행"
}

/// 키를 두는 곳의 꼴 (`ClaudeAPIKey.storage`).
protocol ClaudeAPIKeyStorage: AnyObject {
    func load() -> String?
    func save(_ key: String) -> Bool
    func delete()
}

/// macOS 키체인의 일반 암호 하나 (이 Mac 의 로그인 키체인).
final class ClaudeAPIKeyKeychainStorage: ClaudeAPIKeyStorage {
    private let service = "com.agenthandoffconsole.claude-api-key"
    private let account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// 시험용 — 메모리에만 둔다.
final class ClaudeAPIKeyMemoryStorage: ClaudeAPIKeyStorage {
    private(set) var value: String?
    private(set) var loads = 0
    var failsToSave = false

    init(_ value: String? = nil) { self.value = value }

    func load() -> String? { loads += 1; return value }
    func save(_ key: String) -> Bool {
        guard !failsToSave else { return false }
        value = key
        return true
    }
    func delete() { value = nil }
}
