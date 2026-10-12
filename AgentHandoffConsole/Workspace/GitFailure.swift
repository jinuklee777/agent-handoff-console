import Foundation

/// git 쓰기가 실패했을 때 그 출력(`GitWrite.Outcome.output`, stdout + stderr)을 분류한다. **순수 함수**라
/// 오프라인 검증(`WorkspaceTests` "Git 실패 분류")에서 실측 문장으로 그대로 확인한다.
///
/// 원칙: 출력에 있는 것만으로 분류한다. 분류되지 않으면 git 이 쓴 한 줄을 **글자 그대로** 보여준다
/// (원인 · 도구 이름 · 개수를 지어내지 않는다). 전문은 "오류 전문" · "출력 보기" 와 대화 기록에 남는다.
///
/// git 의 말은 어느 git 이냐에 따라 다르다 (2026-09-13 이 Mac 실측). 앱이 찾는 git(`GitInspector.findGit`)은
/// `/usr/bin/git`(Apple Git 2.50) 이 먼저라 로케일과 관계없이 영어로 말한다. 번역 파일이 있는 git(Homebrew 2.42)은
/// macOS 언어 설정을 따라 한국어로 말한다 — ref 상태 줄(`! [rejected] … (fetch first)`), 머리말 `error:` · `fatal:`,
/// 인증 문장("Authentication failed" 등)과 "Diverging branches" 힌트는 영어, 나머지는 한국어였다. 번역 파일에는
/// `[rejected]` → `[거부됨]`, `non-fast-forward` → `정방향 진행이 아님` 도 있다. 그래서 규칙은 영어 원문과
/// 한국어 번역을 모두 본다. 앱은 git 의 언어를 바꾸지 않는다 (사용자가 대화 기록에서 보는 출력은 그대로다).
enum GitFailure: Equatable, Sendable {
    /// 원격과 기록이 갈라져 git 이 거절했다. push: `[rejected]` + non-fast-forward · fetch first,
    /// pull `--ff-only`: 앞으로 감기(fast-forward) 불가.
    case diverged
    /// 원격 저장소에 로그인하지 못했다. `gitHub` = 원격 주소의 host 가 github.com 이다 (모르면 false).
    case authentication(gitHub: Bool)
    /// 받기 · 전환이 내 파일을 덮어쓰게 되어 git 이 멈췄다. 출력에 나온 파일 이름 (못 읽으면 빈 배열).
    case overlappingChanges([String])
    /// 커밋할 것이 없다.
    case nothingToCommit
    /// git 사용자 이름 · 이메일이 설정되어 있지 않다.
    case identityUnknown
    /// 그 브랜치를 다른 git worktree(앱이 만든 독립 작업 폴더일 수 있다)가 쓰고 있어 전환하지 않았다. 출력에 나온 그 폴더 (못 읽으면 nil).
    case branchInOtherWorktree(String?)
    /// 분류하지 못했다. git 이 쓴 한 줄을 그대로 (출력이 없으면 그 사실).
    case unclassified(String)

    static let noOutputLine = "git 이 실패로 끝났습니다. 출력이 없습니다."

    // MARK: - 분류

    /// `remoteURL` 은 명령이 말을 건 원격의 주소 (`GitWorkspace.remoteURL`). GitHub 인지 가릴 때만 쓴다.
    static func classify(_ operation: GitWrite.Operation, output: String, remoteURL: String? = nil) -> GitFailure {
        let lines = output.components(separatedBy: .newlines)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .unclassified(noOutputLine)
        }
        let lower = output.lowercased()
        switch operation {
        case .push:
            if isAuthentication(lower) { return .authentication(gitHub: isGitHub(remoteURL: remoteURL, output: lower)) }
            if isPushRejectedForHistory(lines) { return .diverged }
        case .pull:
            if isAuthentication(lower) { return .authentication(gitHub: isGitHub(remoteURL: remoteURL, output: lower)) }
            if isOverlap(lower) { return .overlappingChanges(overlappingFiles(lines)) }
            if isPullNotFastForward(lower) { return .diverged }
        case .fetch:
            if isAuthentication(lower) { return .authentication(gitHub: isGitHub(remoteURL: remoteURL, output: lower)) }
        case .commit:
            if isNothingToCommit(lower) { return .nothingToCommit }
            if isIdentityUnknown(lower) { return .identityUnknown }
        case .switchBranch, .createBranch:
            if isOverlap(lower) { return .overlappingChanges(overlappingFiles(lines)) }
            if isBranchInOtherWorktree(lower) { return .branchInOtherWorktree(otherWorktreePath(lines)) }
        case .stage, .unstage:
            break
        }
        return .unclassified(verbatimLine(lines, preferRefStatus: operation.isPush))
    }

    /// 로그인 실패. 이 문장들은 번역 항목이 없어 영어로 나온다 (실측).
    static func isAuthentication(_ lower: String) -> Bool {
        ["authentication failed", "could not read username", "could not read password",
         "permission denied (publickey", "terminal prompts disabled"].contains { lower.contains($0) }
    }

    /// push 거절 중 "원격에 이 브랜치에 없는 커밋이 있다" 는 것만. `[remote rejected]`(서버 훅 · 보호 브랜치)는
    /// 기록 문제가 아니라 여기 들지 않는다 (`[rejected]` 는 그 안의 부분 문자열이 아니다).
    static func isPushRejectedForHistory(_ lines: [String]) -> Bool {
        let reasons = ["non-fast-forward", "fetch first", "정방향 진행이 아님"]
        return lines.contains { line in
            (line.contains("[rejected]") || line.contains("[거부됨]")) && reasons.contains { line.contains($0) }
        }
    }

    /// `pull --ff-only` 가 기록이 갈라져 멈췄다.
    static func isPullNotFastForward(_ lower: String) -> Bool {
        ["not possible to fast-forward", "diverging branches", "정방향이 불가능"].contains { lower.contains($0) }
    }

    /// 받기 · 전환이 로컬 변경(추적 · 새 파일)을 덮어쓰게 되어 멈췄다.
    static func isOverlap(_ lower: String) -> Bool {
        ["would be overwritten by", "덮어 쓰게 됩니다", "덮어씁니다"].contains { lower.contains($0) }
    }

    /// 다른 worktree 가 그 브랜치를 쓰고 있다 (git 2.4x "is already used by worktree at", 예전 "is already checked out at").
    static func isBranchInOtherWorktree(_ lower: String) -> Bool {
        ["is already used by worktree at", "is already checked out at"].contains { lower.contains($0) }
    }

    /// 그 문장 끝의 작은따옴표 안 경로 (`… at '/path'`). 없으면 nil.
    static func otherWorktreePath(_ lines: [String]) -> String? {
        guard let line = lines.first(where: { isBranchInOtherWorktree($0.lowercased()) }),
              let at = line.range(of: " at '", options: .backwards) else { return nil }
        let rest = line[at.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        let path = String(rest[..<end])
        return path.isEmpty ? nil : path
    }

    static func isNothingToCommit(_ lower: String) -> Bool {
        ["nothing to commit", "nothing added to commit", "no changes added to commit",
         "커밋할 사항 없음", "커밋할 사항을 추가하지 않았지만", "커밋할 변경 사항을 추가하지 않았습니다"]
            .contains { lower.contains($0) }
    }

    static func isIdentityUnknown(_ lower: String) -> Bool {
        ["please tell me who you are", "author identity unknown", "committer identity unknown",
         "unable to auto-detect email address", "empty ident name",
         "내가 누구인지 설정하십시오", "메일 주소를 자동 검사할 수 없습니다", "빈 이름의 신원 정보"]
            .contains { lower.contains($0) }
    }

    /// 덮어쓰게 된다고 한 줄 다음의 들여쓴 줄들이 파일 이름이다 (git 은 탭으로 들여 쓴다).
    /// 추적 파일 · 새 파일 두 목록이 함께 나올 수 있어 모두 모으고 겹치는 이름은 한 번만.
    static func overlappingFiles(_ lines: [String]) -> [String] {
        var files: [String] = []
        var collecting = false
        for line in lines {
            if isOverlap(line.lowercased()) {
                collecting = true
                continue
            }
            guard collecting else { continue }
            if let first = line.first, first == "\t" || first == " " {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !files.contains(name) { files.append(name) }
            } else {
                collecting = false
            }
        }
        return files
    }

    /// 분류하지 못했을 때 보여줄 한 줄 (글자 그대로). push 는 ref 상태 줄(`! [remote rejected] … (이유)`)이
    /// 가장 구체적이라 먼저, 그다음 `error:` · `fatal:` 줄, 없으면 힌트가 아닌 마지막 줄.
    static func verbatimLine(_ lines: [String], preferRefStatus: Bool = false) -> String {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if preferRefStatus, let ref = trimmed.first(where: { $0.hasPrefix("! ") }) {
            return ref
        }
        if let line = trimmed.first(where: {
            let lower = $0.lowercased()
            return lower.hasPrefix("error:") || lower.hasPrefix("fatal:") || $0.hasPrefix("오류:")
        }) {
            return line
        }
        let hint = { (line: String) in line.lowercased().hasPrefix("hint:") || line.hasPrefix("힌트:") }
        return trimmed.last(where: { !hint($0) }) ?? trimmed.last ?? noOutputLine
    }

    /// 원격이 github.com 인지. host 가 정확히 github.com(ssh.github.com)일 때만 true
    /// (ssh 별칭 · GitHub Enterprise · `github.company.com` 은 GitHub 로 보지 않는다).
    ///
    /// 1. 출력에 주소가 적혀 있으면(`Authentication failed for 'https://…'`) 그것이 git 이 실제로 말을 건 곳이다
    ///    (insteadOf · pushurl 을 거친 뒤) — 그 host 로 판단한다.
    /// 2. 없으면 앱이 읽은 원격 주소(`remoteURL`)의 host.
    /// 3. 둘 다 없으면 ssh 가 쓰는 `git@github.com: Permission denied` 처럼 host 가 `:` · `/` 바로 앞에서 끝나는 경우만.
    static func isGitHub(remoteURL: String?, output lower: String) -> Bool {
        let hosts = urlHosts(in: lower)
        if !hosts.isEmpty { return hosts.allSatisfy(isGitHubHost) }
        if let remoteURL {
            return GitWorkspace.host(ofRemoteURL: remoteURL).map(isGitHubHost) ?? false
        }
        return lower.contains("@github.com:") || lower.contains("@github.com/")
    }

    static func isGitHubHost(_ host: String) -> Bool {
        host == "github.com" || host == "ssh.github.com"
    }

    /// 출력에 적힌 `scheme://` 주소들의 host (따옴표 · 공백으로 나눈 조각에서). 로컬 경로 · file:// 는 뺀다.
    static func urlHosts(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"`")))
            .filter { $0.contains("://") }
            .compactMap { GitWorkspace.host(ofRemoteURL: $0) }
    }

    // MARK: - 화면 문구

    /// 화면에 쓸 제목과 설명. `verbatim` 이면 설명이 git 이 쓴 글자 그대로라 고정폭으로 보인다.
    struct Explanation: Equatable, Sendable {
        var title: String
        var detail: String
        var verbatim = false
    }

    /// `remoteName` 은 명령이 말을 건 원격 (`GitWorkspace.remoteName`). 모르면 "원격 저장소".
    func explanation(for operation: GitWrite.Operation, remoteName: String? = nil) -> Explanation {
        let title = Self.failedTitle(operation)
        switch self {
        case .diverged:
            if operation.isPush {
                return Explanation(title: title,
                                   detail: "원격에 이 브랜치에 없는 커밋이 있어 git 이 업로드를 거절했습니다. "
                                       + "원격 변경과 합친 다음 다시 업로드하세요. 앱은 원격 기록과 합치거나 강제로 업로드하지 않습니다.")
            }
            return Explanation(title: title,
                               detail: "로컬과 원격 기록이 갈라져 있어 git 이 받지 않았습니다 (git pull --ff-only). "
                                   + "터미널에서 두 기록을 합치세요. 앱은 원격 기록과 합치지 않습니다.")
        case .authentication(let gitHub):
            let target = remoteName.map { "\($0) 에" } ?? "원격 저장소에"
            if gitHub {
                // 명령은 새 줄 맨 앞에 둔다 — 문장 중간에 두면 좁은 폭에서 `gh` 와 `auth login` 이 두 줄로 갈린다.
                // (줄바꿈 없는 공백은 복사해 터미널에 붙이면 한 낱말이 되어 쓰지 않는다.)
                return Explanation(title: "GitHub 로그인이 필요합니다",
                                   detail: "\(target) 로그인하지 못했습니다. 앱은 자격 증명을 묻지 않습니다.\n"
                                       + "gh auth login 을 터미널에서 실행해 로그인한 뒤 다시 시도하세요.")
            }
            return Explanation(title: "원격 저장소 로그인이 필요합니다",
                               detail: "\(target) 로그인하지 못했습니다. 앱은 자격 증명을 묻지 않습니다. "
                                   + "터미널에서 이 원격의 자격 증명을 설정한 뒤 다시 시도하세요.")
        case .overlappingChanges(let files):
            let names = Self.fileList(files)
            switch operation {
            case .switchBranch, .createBranch:
                return Explanation(title: title,
                                   detail: "겹치는 파일이 있어 전환하지 않았습니다" + (names.map { ": \($0)" } ?? "") + ". "
                                       + "먼저 커밋하거나 치운 뒤 다시 전환하세요.")
            default:
                // 받기는 `pull --ff-only` 라, 겹치는 변경을 지금 커밋하면 기록이 갈라져 받기가 반드시 실패한다.
                // 커밋을 권하지 않는다.
                return Explanation(title: title,
                                   detail: "내 파일과 겹치는 변경이 있어 받지 않았습니다" + (names.map { ": \($0)" } ?? "") + ". "
                                       + "지금 커밋하면 기록이 갈라져 앱에서 받을 수 없게 됩니다. "
                                       + "터미널에서 그 변경을 치운 뒤 다시 받으세요.")
            }
        case .nothingToCommit:
            return Explanation(title: title, detail: "커밋할 변경이 없습니다. 이미 커밋됐거나 선택이 바뀌었을 수 있습니다.")
        case .identityUnknown:
            return Explanation(title: title,
                               detail: "git 사용자 이름 · 이메일이 설정되어 있지 않습니다. 터미널에서 git config 로 설정하세요.")
        case .branchInOtherWorktree(let path):
            return Explanation(title: title,
                               detail: "이 브랜치는 다른 git worktree" + (path.map { "(\($0))" } ?? "") + "가 쓰고 있어 git 이 전환하지 않았습니다. "
                                   + "앱이 만든 독립 작업 폴더의 브랜치(ahc/…)면 그 대화의 변경사항 탭에서 합치거나 정리하세요.")
        case .unclassified(let line):
            return Explanation(title: title, detail: line, verbatim: true)
        }
    }

    /// 파일 이름 최대 3개 + "외 n개". 없으면 nil (이름을 지어내지 않는다).
    static func fileList(_ files: [String]) -> String? {
        guard !files.isEmpty else { return nil }
        let shown = files.prefix(3).joined(separator: ", ")
        return files.count > 3 ? "\(shown) 외 \(files.count - 3)개" : shown
    }

    static func failedTitle(_ operation: GitWrite.Operation) -> String {
        switch operation {
        case .push(_, true): return "브랜치를 업로드하지 못했습니다"
        case .push: return "업로드하지 못했습니다"
        case .pull: return "원격 변경을 받지 못했습니다"
        case .fetch: return "원격 상태를 확인하지 못했습니다"
        case .commit: return "커밋하지 못했습니다"
        case .switchBranch: return "전환하지 못했습니다"
        case .createBranch: return "브랜치를 만들지 못했습니다"
        case .stage: return "커밋에 포함하지 못했습니다"
        case .unstage: return "커밋에서 빼지 못했습니다"
        }
    }

    /// 커밋 실패 이유 한 줄 (변경사항 탭 커밋 독).
    static func commitSummary(_ output: String) -> String {
        let operation = GitWrite.Operation.commit(message: "-")
        return classify(operation, output: output).explanation(for: operation).detail
    }
}

extension GitWrite.Operation {
    /// 원격으로 올리는 명령 (업로드 · 게시).
    var isPush: Bool {
        if case .push = self { return true }
        return false
    }

    /// 원격에 말을 거는 명령. 실패하면 변경사항 탭 바닥의 동기화 자리에 이유를 보여준다.
    var talksToRemote: Bool {
        switch self {
        case .push, .pull, .fetch: return true
        default: return false
        }
    }
}
