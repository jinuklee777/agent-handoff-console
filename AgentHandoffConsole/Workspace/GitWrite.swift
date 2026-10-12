import Foundation

/// 작업 폴더를 **바꾸는** git 명령. 읽기 전용 조회(`GitWorkspace`)와 파일을 나눠 둔다.
///
/// 규칙:
/// - **되돌리기 어려운 명령은 앱이 대신하지 않는다.** `reset --hard`, `clean`, `checkout -- <파일>`,
///   `push --force`, 브랜치·태그 삭제는 여기 없다. 필요하면 사용자가 터미널에서 직접 한다.
/// - 실행한 명령과 출력을 그대로 돌려준다. 호출자가 대화에 기록해 인계 문서까지 이어지게 한다.
/// - **자격 증명을 다루지 않는다.** `GIT_TERMINAL_PROMPT=0` 이라 인증이 필요하면 묻지 않고 실패한다
///   (사용자가 터미널에서 `gh auth login` 등으로 미리 설정해 둔 자격 증명만 쓴다).
/// - 커밋 메시지는 인수가 아니라 stdin(`git commit -F -`) 으로 넘긴다. `ps` 노출과 따옴표 문제를 피한다.
enum GitWrite {

    enum Operation: Sendable, Equatable {
        case stage([String])
        case unstage([String])
        case commit(message: String)
        case createBranch(String)
        case switchBranch(String)
        case fetch
        case pull
        case push(branch: String, setUpstream: Bool)

        /// 사람에게 물어야 하는 동작인지 (밖으로 나가거나 남의 기록을 바꾸는 것).
        var needsConfirmation: Bool {
            switch self {
            case .push: return true
            case .pull: return true
            default: return false
            }
        }

        /// 대화 기록에 남기는 명령인지. 체크박스(커밋에 포함 · 빼기)는 누를 때마다 대화에 쌓이므로 남기지 않는다 —
        /// 무엇이 기록됐는지는 커밋이 남긴다 (chg-18).
        var isRecordedInConversation: Bool {
            switch self {
            case .stage, .unstage: return false
            default: return true
            }
        }

        /// 화면에 쓰는 동작 이름 — 변경사항 탭의 단추 · 체크박스 글과 같은 말 하나 (txt-4). git 명령 이름은 도움말 · 기록에만 쓴다.
        var koreanName: String {
            switch self {
            case .stage: return "커밋에 포함"
            case .unstage: return "커밋에서 빼기"
            case .commit: return "커밋"
            case .createBranch: return "브랜치 만들기"
            case .switchBranch: return "브랜치 전환"
            case .fetch: return "원격 상태 확인"
            case .pull: return "원격 변경 받기"
            case .push(_, true): return "브랜치 업로드"
            case .push: return "업로드"
            }
        }

        /// "… 하는 중입니다" — 보내기 · 잠금 배너가 쓴다 ("git 명령(…)" 틀 없이 동사 하나로).
        var progressText: String {
            switch self {
            case .stage: return "커밋에 포함하는 중입니다"
            case .unstage: return "커밋에서 빼는 중입니다"
            case .commit: return "커밋하는 중입니다"
            case .createBranch: return "브랜치를 만드는 중입니다"
            case .switchBranch: return "브랜치를 전환하는 중입니다"
            case .fetch: return "원격 상태를 확인하는 중입니다"
            case .pull: return "원격 변경을 받는 중입니다"
            case .push(_, true): return "브랜치를 업로드하는 중입니다"
            case .push: return "업로드하는 중입니다"
            }
        }
    }

    struct Outcome: Sendable {
        /// 화면·기록에 보여줄 명령줄 (실제로 실행한 인수 그대로).
        var command: String
        var output: String
        var succeeded: Bool
        /// git 의 종료 코드. 실행하지 못했거나 시간 초과로 끊었으면 nil (기록에 지어 넣지 않는다).
        var exitStatus: Int32? = nil
    }

    /// 명령을 실행할 폴더. 경로를 받는 명령(stage · unstage)의 경로는 `git status` 가 준 **저장소 루트 기준**이라
    /// 루트에서 실행한다 — 프로젝트가 저장소의 하위 폴더면 그 폴더 기준으로 풀려 "일치하는 파일 없음" 이 된다.
    /// 나머지는 프로젝트 폴더에서 실행한다 (지금까지와 같음).
    static func workingDirectory(for operation: Operation, project: URL, repositoryRoot: URL?) -> URL {
        switch operation {
        case .stage, .unstage: return repositoryRoot ?? project
        default: return project
        }
    }

    enum Invalid: Error, Equatable {
        case emptyMessage
        case emptyPaths
        case badBranchName(String)
    }

    /// 실행할 git 인수. 순수 함수라 그대로 검증할 수 있다.
    static func arguments(for operation: Operation) throws -> [String] {
        switch operation {
        case .stage(let paths):
            guard !paths.isEmpty else { throw Invalid.emptyPaths }
            return ["add", "--"] + paths
        case .unstage(let paths):
            guard !paths.isEmpty else { throw Invalid.emptyPaths }
            // 워킹 트리는 건드리지 않고 인덱스만 되돌린다 (`restore --staged`).
            return ["restore", "--staged", "--"] + paths
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Invalid.emptyMessage
            }
            // -F - : 메시지를 stdin 으로. 사용자의 훅·서명 설정은 그대로 따른다.
            return ["commit", "-F", "-"]
        case .createBranch(let name):
            try validateBranchName(name)
            return ["switch", "-c", name]
        case .switchBranch(let name):
            try validateBranchName(name)
            return ["switch", name]
        case .fetch:
            return ["fetch", "--prune"]
        case .pull:
            // 병합 커밋을 앱이 임의로 만들지 않는다. 갈라졌으면 실패하고 사용자가 직접 정리한다.
            return ["pull", "--ff-only"]
        case .push(let branch, let setUpstream):
            try validateBranchName(branch)
            // --force 는 제공하지 않는다.
            return setUpstream ? ["push", "--set-upstream", "origin", branch] : ["push"]
        }
    }

    /// 브랜치 이름 검사. git 이 거부할 이름을 미리 막아 오류 메시지를 이해하기 쉽게 한다.
    static func validateBranchName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 200,
              !trimmed.hasPrefix("-"), !trimmed.hasPrefix("/"), !trimmed.hasSuffix("/"),
              !trimmed.hasSuffix(".lock"), trimmed != "@",
              !trimmed.contains(".."), !trimmed.contains("@{"), !trimmed.contains("//"),
              trimmed.range(of: #"[\s~^:?*\[\\]"#, options: .regularExpression) == nil,
              trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F })
        else { throw Invalid.badBranchName(name) }
    }

    /// 쓰기용 환경. 조회와 달리 잠금은 정상적으로 잡되, 자격 증명 프롬프트는 막는다.
    static func writeEnvironment(_ environment: [String: String]) -> [String: String] {
        var env = environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        // 에디터가 열려 앱이 멈추는 일이 없도록 한다 (메시지는 stdin 으로 준다).
        env["GIT_EDITOR"] = "true"
        return env
    }

    /// 경로가 이보다 많으면 인수 대신 stdin 으로 넘긴다 (`--pathspec-from-file=-`). 새 파일 수천 개를 "전체 선택" 해도
    /// 인수 길이 한도(ARG_MAX, macOS 1MB)에 걸리지 않게 (chg-18).
    static let pathspecArgumentLimit = 200

    /// 경로를 stdin 으로 넘길 때의 인수 (경로 없이). 경로를 받는 명령이 아니면 nil.
    static func pathspecFileArguments(for operation: Operation) -> [String]? {
        switch operation {
        case .stage: return ["add", "--pathspec-from-file=-"]
        case .unstage: return ["restore", "--staged", "--pathspec-from-file=-"]
        default: return nil
        }
    }

    /// stdin 한 줄에 쓸 경로. git 은 줄마다 경로 하나를 읽고, 큰따옴표로 시작하는 줄은 C 문자열로 푼다 — 줄바꿈 · 큰따옴표로
    /// 시작하는 이름은 C 문자열로 감싼다 (그 밖에는 글자 그대로).
    static func pathspecLine(_ path: String) -> String {
        guard path.hasPrefix("\"") || path.contains("\n") || path.contains("\r") else { return path }
        var out = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func perform(_ operation: Operation, git: String, at directory: URL,
                        environment: [String: String],
                        timeout: TimeInterval = 120) async -> Outcome {
        var args: [String]
        do {
            args = try arguments(for: operation)
        } catch {
            return Outcome(command: operation.koreanName,
                           output: describe(error), succeeded: false)
        }
        var stdin: [String] = []
        if case .commit(let message) = operation { stdin = [message] }
        var env = writeEnvironment(environment)
        var pathCount: Int?
        switch operation {
        case .stage(let paths), .unstage(let paths):
            // 파일 경로는 글자 그대로다. `a[1].txt` 를 고르면 `a1.txt` 까지 함께 스테이지되지 않게 한다 (stdin 으로 넘겨도 같다).
            env["GIT_LITERAL_PATHSPECS"] = "1"
            if paths.count > pathspecArgumentLimit, let fileArgs = pathspecFileArguments(for: operation) {
                args = fileArgs
                stdin = paths.map(pathspecLine)
                pathCount = paths.count
            }
        default:
            break
        }

        // 성공 여부는 종료 코드로만 판단한다. 훅이 stdout 에 쓰고 실패해도 실패다.
        var result = await CLIEnvironment.captureProcess(
            executable: git, arguments: GitInspector.commandArguments(args), environment: env,
            workingDirectory: directory, stdinLines: stdin, timeout: timeout)
        var used = args
        // 커밋이 하나도 없는 저장소에는 HEAD 가 없어 `restore --staged` 가 실패한다.
        // 이때의 동치는 `rm --cached` 다 (워킹 트리의 파일은 그대로 둔다).
        if !result.succeeded, case .unstage(let paths) = operation,
           result.combinedOutput.contains("HEAD") {
            used = pathCount == nil ? ["rm", "--cached", "-q", "--"] + paths : ["rm", "--cached", "-q", "--pathspec-from-file=-"]
            result = await CLIEnvironment.captureProcess(
                executable: git, arguments: GitInspector.commandArguments(used), environment: env,
                workingDirectory: directory, stdinLines: pathCount == nil ? [] : paths.map(pathspecLine), timeout: timeout)
        }
        let command = "git " + used.joined(separator: " ") + (pathCount.map { " (경로 \($0)개)" } ?? "")
        // push · fetch 는 결과를 stderr 에 쓰므로 성공해도 두 출력을 함께 남긴다.
        return Outcome(command: command, output: result.combinedOutput, succeeded: result.succeeded,
                       exitStatus: result.note == nil ? result.exitStatus : nil)
    }

    /// 저장소가 아닌 폴더에서 기록을 시작한다 (`git init` — 확인을 받은 뒤, 변경사항 탭의 "이 폴더에서 git 시작하기", chg-23).
    /// 파일은 건드리지 않는다 (첫 커밋은 하지 않는다 — 사람이 고른 파일을 커밋한다).
    static func initRepository(git: String, at directory: URL, environment: [String: String]) async -> Outcome {
        let args = ["init"]
        let result = await CLIEnvironment.captureProcess(executable: git, arguments: GitInspector.commandArguments(args),
                                                         environment: writeEnvironment(environment),
                                                         workingDirectory: directory, timeout: 30)
        return Outcome(command: "git " + args.joined(separator: " "), output: result.combinedOutput,
                       succeeded: result.succeeded, exitStatus: result.note == nil ? result.exitStatus : nil)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case Invalid.emptyMessage: return "커밋 메시지가 비어 있습니다."
        case Invalid.emptyPaths: return "대상 파일이 없습니다."
        case Invalid.badBranchName(let name): return "브랜치 이름으로 쓸 수 없습니다: \(name)"
        default: return error.localizedDescription
        }
    }
}
