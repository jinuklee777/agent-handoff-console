import Foundation

/// 실측 기록(`scripts/probe/<도구>/logs/<이름>.jsonl`)을 읽는 재생 시험 도우미.
///
/// 한 줄 = `{"t":초,"ev":{CLI 가 낸 JSON}}` 또는 `{"t":..,"driver":"sent|start|main_thread|action|…", …}`.
/// 기록이 없으면 **실패로 알린다** — 조용히 건너뛰면 재생 시험이 통과한 것처럼 보인다.
enum ProbeLogs {
    struct Record {
        /// 기록 시작부터의 초.
        var t: Double
        /// CLI 가 낸 JSON 한 줄 (`ev`). 기록 도구의 메모면 nil.
        var event: [String: Any]?
        /// 기록 도구의 메모 종류 (`driver`). CLI 줄이면 nil.
        var driver: String?
        /// 줄 전체.
        var raw: [String: Any]

        /// 알림(method 는 있고 id 는 없는 CLI 줄)이면 그 method.
        var notificationMethod: String? {
            guard let event, event["id"] == nil else { return nil }
            return event["method"] as? String
        }
        var params: [String: Any] { event?["params"] as? [String: Any] ?? [:] }
        /// 기록 도구가 CLI 에 보낸 것 (`driver == "sent"`).
        var sent: [String: Any]? { driver == "sent" ? raw["obj"] as? [String: Any] : nil }
    }

    enum LoadError: Error, CustomStringConvertible {
        case noRepoRoot(tried: [String])
        case missing(String)
        case unreadable(String, line: Int)

        var description: String {
            switch self {
            case .noRepoRoot(let tried): return "저장소 뿌리를 찾지 못함 (시도: \(tried.joined(separator: ", ")))"
            case .missing(let path): return "기록 없음: \(path)"
            case .unreadable(let path, let line): return "해석 실패: \(path) \(line)번째 줄"
            }
        }
    }

    /// 저장소 뿌리 후보: 환경변수 `AHC_REPO_ROOT` → 실행 파일(`<뿌리>/build/inttest/inttest`)에서 세 단계 위 → 현재 폴더.
    /// `scripts/probe` 가 있는 첫 후보를 쓴다.
    static func repoRoot() -> Result<URL, LoadError> {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["AHC_REPO_ROOT"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent())
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        for root in candidates {
            var isDir: ObjCBool = false
            let probe = root.appendingPathComponent("scripts/probe").path
            if FileManager.default.fileExists(atPath: probe, isDirectory: &isDir), isDir.boolValue {
                return .success(root.standardizedFileURL)
            }
        }
        return .failure(.noRepoRoot(tried: candidates.map(\.path)))
    }

    /// `scripts/probe/<probe>/logs/<name>.jsonl` 을 줄 순서대로 읽는다.
    static func load(probe: String, name: String) -> Result<[Record], LoadError> {
        let root: URL
        switch repoRoot() {
        case .success(let r): root = r
        case .failure(let e): return .failure(e)
        }
        let url = root.appendingPathComponent("scripts/probe/\(probe)/logs/\(name).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(.missing(url.path))
        }
        var records: [Record] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let object = JSONUtil.object(String(line)) else {
                return .failure(.unreadable(url.path, line: index + 1))
            }
            records.append(Record(t: JSONUtil.double(object["t"]) ?? 0,
                                  event: object["ev"] as? [String: Any],
                                  driver: object["driver"] as? String,
                                  raw: object))
        }
        return .success(records)
    }

    /// 시험에서 쓰는 입구: 읽지 못하면 실패 항목을 남기고 nil.
    static func require(_ t: TestKit, probe: String, name: String) async -> [Record]? {
        switch load(probe: probe, name: name) {
        case .success(let records):
            guard !records.isEmpty else {
                await t.check("실측 기록 \(name)", false, "빈 기록")
                return nil
            }
            return records
        case .failure(let error):
            await t.check("실측 기록 \(name)", false, error.description)
            return nil
        }
    }
}
