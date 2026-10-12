import Foundation

// 새 대화 · 처음 쓰는 에이전트의 모델 · 강도 기본값 (사용자 결정 2026-10-04).
// 차례: 대화에 고른 모델 → 같은 프로젝트에서 그 에이전트로 마지막에 쓴 대화의 모델 · 강도 → 전체에서 마지막 →
// Codex 는 계정 홈의 config.toml `model`(목록에 있으면) → CLI 가 표시한 기본(`isDefault`).
// 고르지 않은 강도는 `EffortScale.resolvedDefault` (설정의 기본 강도 → Codex 는 config.toml → 그 모델의 기본 → High).
// SwiftUI · 저장 없이 — 검증 하네스가 컴파일한다. 앱 쪽은 `AppModel.effectiveSelection` · `pinEffectiveSelection`.

/// Codex 계정 홈의 `config.toml` 에서 읽은 기본값 — 최상위 `model` · `model_reasoning_effort`. 최상위 `profile` 이 있으면
/// `[profiles.<이름>]` 표의 값이 앞선다 (Codex 가 쓰는 값과 같게). 앱은 이 파일을 **읽기만** 한다.
struct CodexConfigDefaults: Equatable, Sendable {
    var model: String?
    var effort: String?

    /// TOML 의 필요한 부분만 읽는다: 최상위 키 셋과 프로필 표. 여러 줄 문자열 안 · 주석은 건너뛴다. 읽지 못하면 빈 값.
    static func parse(_ toml: String?) -> CodexConfigDefaults {
        guard let toml else { return CodexConfigDefaults() }
        var top: [String: String] = [:]
        var tables: [String: [String: String]] = [:]
        var table: String?   // nil = 최상위
        var openDelimiter: String?
        for raw in toml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let rawLine = String(raw)
            if let delimiter = openDelimiter {
                if rawLine.contains(delimiter) { openDelimiter = nil }
                continue
            }
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                // `[profiles.fast]` · `[profiles."fast"]` · `[[배열 표]]` — 이름만 남긴다.
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                table = name
                continue
            }
            if let delimiter = opensMultilineString(line) {
                openDelimiter = delimiter
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = unquoted(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty else { continue }
            if let table { tables[table, default: [:]][key] = value } else { top[key] = value }
        }
        var result = CodexConfigDefaults(model: top["model"], effort: top["model_reasoning_effort"])
        if let profile = top["profile"], let values = tables["profiles.\(profile)"] {
            if let model = values["model"] { result.model = model }
            if let effort = values["model_reasoning_effort"] { result.effort = effort }
        }
        return result
    }

    /// 따옴표 밖의 `#` 부터가 주석이다.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// 이 줄의 값이 여러 줄 문자열을 열고 닫지 않았으면 그 따옴표(`"""` · `'''`). 한 줄 안에서 열고 닫으면 nil.
    private static func opensMultilineString(_ line: String) -> String? {
        for delimiter in ["\"\"\"", "'''"] where (line.components(separatedBy: delimiter).count - 1) % 2 == 1 {
            return delimiter
        }
        return nil
    }

    /// 계정 홈의 `config.toml` 을 읽는다 (`~` 를 푼다). 파일의 수정 시각이 그대로면 지난번 값을 쓴다 — 화면이 다시 그려질 때마다 부른다.
    static func read(home: String) -> CodexConfigDefaults {
        if let readOverride { return readOverride(home) }
        let path = (home as NSString).expandingTildeInPath + "/config.toml"
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = lock.withLock({ cache[path] }), cached.modified == modified { return cached.value }
        let value = modified == nil ? CodexConfigDefaults() : parse(try? String(contentsOfFile: path, encoding: .utf8))
        lock.withLock { cache[path] = (modified, value) }
        return value
    }

    /// 검증 하네스용: 있으면 파일 대신 이것을 돌려준다 — 사람의 `~/.codex/config.toml` 에 따라 시험 결과가 달라지지 않게. 앱은 두지 않는다.
    nonisolated(unsafe) static var readOverride: ((String) -> CodexConfigDefaults)?

    private static let lock = UnfairLock()
    nonisolated(unsafe) private static var cache: [String: (modified: Date?, value: CodexConfigDefaults)] = [:]
}

/// 고르지 않은 모델의 기본값 — 이어받기의 순수 판정.
enum ModelDefaults {

    /// 사람이 정한 모델이 있는 선택인가. nil · 빈 값 · Claude 의 "default" 는 정하지 않은 것이다 — 앱이 만들 때 넣은 강도만 있는
    /// 선택(모델 nil)은 사람이 고른 것이 아니다 (화면 · 보내기가 이어받기 · 기본으로 푼다).
    static func hasChosenModel(_ selection: ModelSelection, provider: AgentProvider) -> Bool {
        guard let model = selection.model, !model.isEmpty else { return false }
        return !(provider == .claude && model == "default")
    }

    /// 이어받을 선택: 같은 프로젝트에서 그 에이전트로 마지막에 쓴 대화의 모델 · 강도 → 전체에서 마지막.
    /// 후보는 그 에이전트의 모델을 정해 둔 대화뿐이다 — 보낸 대화는 모델이 채워지고(`AppModel.send`), 사람이 고른 대화도 그렇다.
    /// "마지막에 쓴" 은 기록이 없어 대화의 상태로 가늠한다: 지금 그 에이전트를 쓰는(입력창의 에이전트) 대화가 먼저, 그 안에서 최근에
    /// 바뀐 것(`updatedAt` — 보내기 · 모델 고르기가 올린다)이 먼저. 내부 대화(자동 작업)와 `excluding` 은 뺀다.
    /// `accepts` 가 false 인 모델(받을 계정의 목록에서 풀리지 않는다)은 건너뛴다.
    static func inherited(provider: AgentProvider, projectID: String, excluding threadID: String?,
                          threads: [ConversationThread], accepts: (String) -> Bool = { _ in true }) -> ModelSelection? {
        let ordered = threads.filter { $0.id != threadID && !$0.isInternal }.sorted { a, b in
            let aUses = a.preferredProvider == provider, bUses = b.preferredProvider == provider
            if aUses != bUses { return aUses }
            return a.updatedAt > b.updatedAt
        }
        for sameProject in [true, false] {
            for thread in ordered where !sameProject || thread.projectID == projectID {
                let selection = thread.selection(for: provider)
                guard hasChosenModel(selection, provider: provider), let model = selection.model, accepts(model) else { continue }
                return ModelSelection(model: model, effort: selection.effort.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        return nil
    }
}
