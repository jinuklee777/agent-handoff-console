import Foundation

/// 현재 브랜치의 Pull Request. `gh` 가 준 값만 담는다.
struct PullRequestInfo: Hashable, Sendable {
    struct Check: Hashable, Sendable, Identifiable {
        enum Outcome: Sendable { case pass, fail, pending, skipped, neutral }
        var id: String
        var name: String
        var detail: String?
        var outcome: Outcome
        var duration: TimeInterval?
    }

    struct Review: Hashable, Sendable, Identifiable {
        var id: String
        var author: String
        /// APPROVED · CHANGES_REQUESTED · COMMENTED · DISMISSED · PENDING
        var state: String
        var body: String
        var submittedAt: Date?
    }

    var number: Int
    var title: String
    /// OPEN · CLOSED · MERGED
    var state: String
    var isDraft: Bool
    var url: String
    var headRefName: String
    var baseRefName: String
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var createdAt: Date?
    /// APPROVED · CHANGES_REQUESTED · REVIEW_REQUIRED · nil
    var reviewDecision: String?
    var checks: [Check]
    var reviews: [Review]
}

struct PullRequestSummary: Hashable, Sendable, Identifiable {
    var id: Int { number }
    var number: Int
    var title: String
    var state: String
    var isDraft: Bool
    var headRefName: String
}

enum PullRequestState: Equatable, Sendable {
    /// 아직 조회하지 않음 (자동 조회하지 않는다).
    case idle
    case loading
    /// gh 없음 · 로그인 필요 · GitHub 저장소 아님.
    case unavailable(String)
    case none(branch: String, others: [PullRequestSummary])
    case loaded(PullRequestInfo, others: [PullRequestSummary])
    case failed(String)

    var info: PullRequestInfo? {
        if case .loaded(let info, _) = self { return info }
        return nil
    }
}

/// `gh` CLI 로 PR 을 **읽기만** 한다. 코멘트·머지·리뷰 같은 쓰기 동작은 하지 않는다.
enum GitHubCLI {
    static let fields = "number,title,state,isDraft,url,headRefName,baseRefName,additions,deletions,"
        + "changedFiles,createdAt,reviewDecision,statusCheckRollup,latestReviews"

    static func findGH(environment: [String: String]) -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let c = (String(dir) as NSString).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    static func pullRequest(at directory: URL, branch: String?,
                            environment: [String: String]) async -> PullRequestState {
        guard let gh = findGH(environment: environment) else {
            return .unavailable("gh CLI 가 설치되어 있지 않습니다. `brew install gh` 후 `gh auth login`.")
        }
        var overrides = environment
        overrides["GH_PROMPT_DISABLED"] = "1"
        overrides["GH_NO_UPDATE_NOTIFIER"] = "1"
        overrides["NO_COLOR"] = "1"
        let env = overrides

        async let listResult = CLIEnvironment.captureOutput(
            executable: gh, arguments: ["pr", "list", "--state", "all", "--limit", "6",
                                        "--json", "number,title,state,isDraft,headRefName"],
            environment: env, workingDirectory: directory, timeout: 20)
        let viewResult = await CLIEnvironment.captureOutput(
            executable: gh, arguments: ["pr", "view", "--json", fields],
            environment: env, workingDirectory: directory, timeout: 20)

        var others: [PullRequestSummary] = []
        if case .success(let text) = await listResult {
            others = parseList(text)
        }

        switch viewResult {
        case .success(let text):
            guard let info = parseView(text) else {
                return .failed("gh 응답을 해석하지 못했습니다.")
            }
            return .loaded(info, others: others.filter { $0.number != info.number })
        case .failure(let message):
            let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if m.contains("no pull requests found") || m.contains("no open pull requests") {
                return .none(branch: branch ?? "", others: others)
            }
            // "원격이 GitHub 가 아님" 메시지에도 `gh auth login` 안내가 붙어 있으므로 이 검사를 먼저 한다.
            if m.localizedCaseInsensitiveContains("none of the git remotes")
                || m.contains("not a git repository") || m.contains("no git remotes") {
                return .unavailable("GitHub 원격 저장소가 연결된 폴더가 아닙니다.")
            }
            if m.contains("gh auth login") || m.contains("authentication") {
                return .unavailable("gh 로그인이 필요합니다. 터미널에서 `gh auth login`.")
            }
            return .failed(m.isEmpty ? "gh 조회에 실패했습니다." : m)
        }
    }

    // MARK: 해석

    static func parseView(_ text: String) -> PullRequestInfo? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = obj["number"] as? Int else { return nil }

        var checks: [PullRequestInfo.Check] = []
        for (i, item) in ((obj["statusCheckRollup"] as? [[String: Any]]) ?? []).enumerated() {
            checks.append(parseCheck(item, index: i))
        }
        var reviews: [PullRequestInfo.Review] = []
        for (i, item) in ((obj["latestReviews"] as? [[String: Any]]) ?? []).enumerated() {
            let author = (item["author"] as? [String: Any])?["login"] as? String ?? "알 수 없음"
            reviews.append(PullRequestInfo.Review(
                id: item["id"] as? String ?? "review-\(i)", author: author,
                state: item["state"] as? String ?? "", body: item["body"] as? String ?? "",
                submittedAt: date(item["submittedAt"])))
        }

        return PullRequestInfo(
            number: number, title: obj["title"] as? String ?? "",
            state: obj["state"] as? String ?? "", isDraft: obj["isDraft"] as? Bool ?? false,
            url: obj["url"] as? String ?? "", headRefName: obj["headRefName"] as? String ?? "",
            baseRefName: obj["baseRefName"] as? String ?? "",
            additions: obj["additions"] as? Int, deletions: obj["deletions"] as? Int,
            changedFiles: obj["changedFiles"] as? Int, createdAt: date(obj["createdAt"]),
            reviewDecision: (obj["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            checks: checks, reviews: reviews)
    }

    static func parseCheck(_ item: [String: Any], index: Int) -> PullRequestInfo.Check {
        let typename = item["__typename"] as? String ?? ""
        let name = (item["name"] as? String) ?? (item["context"] as? String) ?? "체크 \(index + 1)"
        let outcome: PullRequestInfo.Check.Outcome
        if typename == "StatusContext" {
            switch (item["state"] as? String ?? "").uppercased() {
            case "SUCCESS": outcome = .pass
            case "FAILURE", "ERROR": outcome = .fail
            default: outcome = .pending
            }
        } else {
            let status = (item["status"] as? String ?? "").uppercased()
            if status != "COMPLETED" {
                outcome = .pending
            } else {
                switch (item["conclusion"] as? String ?? "").uppercased() {
                case "SUCCESS": outcome = .pass
                case "SKIPPED": outcome = .skipped
                case "NEUTRAL": outcome = .neutral
                default: outcome = .fail   // FAILURE · CANCELLED · TIMED_OUT · ACTION_REQUIRED
                }
            }
        }
        var duration: TimeInterval?
        if let start = date(item["startedAt"]), let end = date(item["completedAt"]), end > start {
            duration = end.timeIntervalSince(start)
        }
        return PullRequestInfo.Check(id: "\(index)-\(name)", name: name,
                                     detail: item["workflowName"] as? String,
                                     outcome: outcome, duration: duration)
    }

    static func parseList(_ text: String) -> [PullRequestSummary] {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let number = item["number"] as? Int else { return nil }
            return PullRequestSummary(number: number, title: item["title"] as? String ?? "",
                                      state: item["state"] as? String ?? "",
                                      isDraft: item["isDraft"] as? Bool ?? false,
                                      headRefName: item["headRefName"] as? String ?? "")
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty, !s.hasPrefix("0001") else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}
