import Foundation

/// 프로젝트의 검증 명령을 프로젝트 폴더에서 셸로 돌린다.
///
/// 돌리는 명령은 **사용자가 설정에 직접 적은 것뿐**이다. 계획 · 에이전트 출력 · 저장소 문서가 제시한 명령은
/// 여기로 오지 않는다. 로그인 셸(`zsh -lc`)로 돌려 사용자의 PATH 를 그대로 쓴다.
struct ShellVerificationCommandRunner: VerificationCommandRunning {
    /// 끝나지 않는 명령이 오케스트레이션을 붙잡아 두지 않게 한다.
    var timeout: TimeInterval = 15 * 60
    /// 남기는 출력의 끝부분 (바이트). 오류는 대개 끝에 있다.
    var tailLimit = 16_000
    /// 명령의 환경 — 앱은 에이전트 CLI 와 같은 것(`CLIEnvironment.childEnvironment` — 셸의 PATH · 버전 관리자 폴더 포함)을 준다.
    /// 없으면 앱의 환경을 물려받는다: Finder 로 연 앱은 `~/.zshrc` 의 PATH 가 없어 nvm 등으로 설치한 npm 을 찾지 못했다 (ws-3 · set-n3).
    var environment: (@Sendable () async -> [String: String])?

    func run(command: String, in directory: URL) async -> CommandResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = directory
        if let environment { process.environment = await environment() }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = TailBuffer(limit: tailLimit)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }

        func result(_ exitCode: Int?, note: String = "") -> CommandResult {
            CommandResult(command: command, exitCode: exitCode, outputTail: buffer.text + note,
                          durationMs: Int(Date().timeIntervalSince(started) * 1000))
        }

        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return result(nil, note: "실행하지 못했습니다: \(error.localizedDescription)")
        }

        let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = OnceGate()
            process.terminationHandler = { _ in if gate.pass() { continuation.resume(returning: false) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard gate.pass() else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                continuation.resume(returning: true)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { buffer.append(rest) }
        if timedOut { return result(nil, note: "\n(\(Int(timeout))초 안에 끝나지 않아 중단했습니다)") }
        return result(Int(process.terminationStatus))
    }
}

/// 출력의 끝부분만 남기는 버퍼. 읽기 핸들러가 다른 스레드에서 부른다.
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func pass() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
