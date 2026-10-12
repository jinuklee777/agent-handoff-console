import Foundation

/// 앱이 직접 시작한 프로세스에서 나오는 출력.
enum ProcessOutput: Sendable {
    case stdoutLine(String)
    case stderrLine(String)
    /// 프로세스 종료. terminationReason 이 uncaughtSignal 이면 signaled = true.
    case exited(status: Int32, signaled: Bool)
    case launchFailed(String)
}

/// 작업이 취소돼도 정해진 시간만큼 실제로 기다린다. 취소된 작업에서 `Task.sleep` 은 곧바로 던져, `try?` 로 감싼
/// 대기 반복문은 쉬지 않고 돌고(CPU 를 태움) 출력 유예 시간은 0 이 된다 (마지막 출력이 잘림). 프로세스 종료를
/// 기다리거나 남은 출력을 받을 때처럼 **시간 자체가 필요한** 대기에만 쓴다.
func uncancellableSleep(nanoseconds: UInt64) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
            continuation.resume()
        }
    }
}

/// 다른 큐에서 읽은 데이터를 넘겨받는 상자 (세마포어로 기다린 뒤에만 읽는다).
private final class DataBox: @unchecked Sendable {
    var data: Data?
}

/// `Process` + `Pipe` 래퍼.
///
/// 규칙:
/// - 인수는 셸 문자열 조합이 아니라 배열로 전달한다.
/// - stdout 과 stderr 를 동시에 소비한다 (한쪽만 읽으면 파이프 버퍼가 차서 교착된다).
/// - 앱이 시작한 프로세스만 다룬다. 이름으로 다른 사용자 작업을 종료하지 않는다.
final class ManagedProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = UnfairLock()
    /// 파이프 읽기(readabilityHandler)와 종료 시 남은 출력 읽기(terminationHandler)를 한 줄로 세운다.
    /// 2026-09-13 실측: 읽기 핸들러가 막 읽은 조각을 넘기기 전에 종료 처리가 끝나면 그 조각이 스트림이 닫힌 뒤에
    /// 도착해 버려졌다 (짧은 git 조회 450회 중 약 1% 가 출력 없음 — 변경 목록이 비어 보였다).
    /// 종료 처리는 이 잠금으로 진행 중인 조각을 기다린 뒤 `draining` 을 세우고 풀어 준다 — 파이프를 끝까지 읽는
    /// 동안에는 잡고 있지 않는다 (손자 프로세스가 파이프를 쥐고 있어도 두 파이프를 함께 비운다).
    private let drainLock = NSLock()
    /// 종료 처리가 남은 출력을 직접 읽기 시작했다. 이후 읽기 핸들러는 아무것도 읽지 않는다.
    private var draining = false
    private var outFramer = LineFramer()
    private var errFramer = LineFramer()
    private var continuation: AsyncStream<ProcessOutput>.Continuation?
    private var finished = false
    private var stdinClosed = false

    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL?

    private(set) var processIdentifier: Int32 = -1
    /// 띄운 프로세스의 시작 시각 (`ProcessTree.startTime`) — 끌 때 그 PID 가 아직 우리 프로세스인지 확인한다 (PID 재사용).
    private var launchedStart: UInt64?

    /// 끌 때 자손까지 끄는지. 검증 하네스가 예전 동작(직접 띄운 PID 만)과 견줄 때만 끈다 (`inttest releasefix`). 앱은 바꾸지 않는다.
    static var cleansDescendants = true

    init(executable: URL, arguments: [String], workingDirectory: URL?, environment: [String: String]) {
        self.executableURL = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        // 작업 폴더를 주지 않은 보조 명령은 빈 전용 폴더에서 돈다 — 앱의 작업 폴더(`/`)를 물려받으면 Claude CLI 가 거기서
        // 디스크를 훑는다 (`CLIEnvironment.neutralWorkingDirectory`).
        process.currentDirectoryURL = workingDirectory ?? CLIEnvironment.neutralWorkingDirectory()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // 자식이 stdin 을 다 읽기 전에 끝나면 쓰기가 SIGPIPE 로 앱 전체를 종료시킨다.
        // 이 파이프에서만 신호 대신 EPIPE 오류를 받도록 한다 (writeLine 이 false 를 돌려준다).
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// 출력 스트림. 반드시 launch() 전에 만들어 소비를 시작한다.
    func makeStream() -> AsyncStream<ProcessOutput> {
        AsyncStream(bufferingPolicy: .unbounded) { cont in
            self.lock.lock()
            self.continuation = cont
            self.lock.unlock()
            cont.onTermination = { _ in }
        }
    }

    private func emit(_ o: ProcessOutput) {
        lock.lock()
        let c = continuation
        lock.unlock()
        c?.yield(o)
    }

    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        lock.unlock()
        c?.finish()
    }

    func launch() {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.drainLock.lock()
            defer { self.drainLock.unlock() }
            if self.draining { return }
            let data = handle.availableData
            if data.isEmpty {
                self.lock.lock()
                let tail = self.outFramer.flush()
                self.lock.unlock()
                if let tail { self.emit(.stdoutLine(tail)) }
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            let lines = self.outFramer.append(data)
            self.lock.unlock()
            for l in lines { self.emit(.stdoutLine(l)) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.drainLock.lock()
            defer { self.drainLock.unlock() }
            if self.draining { return }
            let data = handle.availableData
            if data.isEmpty {
                self.lock.lock()
                let tail = self.errFramer.flush()
                self.lock.unlock()
                if let tail { self.emit(.stderrLine(tail)) }
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            let lines = self.errFramer.append(data)
            self.lock.unlock()
            for l in lines { self.emit(.stderrLine(l)) }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // 읽기 핸들러가 조각을 넘기는 중이면 끝날 때까지 기다리고, 이후 핸들러는 멈춘다.
            self.drainLock.lock()
            self.draining = true
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.drainLock.unlock()
            // 파이프에 남은 내용을 마저 읽는다. 두 파이프를 함께 읽어, 한쪽을 기다리는 동안 다른 쪽이 차서
            // 막히는 일이 없게 한다 (파이프를 물려받은 손자 프로세스가 계속 쓰는 경우).
            let errDone = DispatchSemaphore(value: 0)
            let errBox = DataBox()
            DispatchQueue.global(qos: .userInitiated).async {
                errBox.data = (try? self.stderrPipe.fileHandleForReading.readToEnd()) ?? nil
                errDone.signal()
            }
            let restOut = (try? self.stdoutPipe.fileHandleForReading.readToEnd()) ?? nil
            errDone.wait()
            let restErr = errBox.data
            self.lock.lock()
            var trailing: [ProcessOutput] = []
            if let restOut, !restOut.isEmpty {
                trailing += self.outFramer.append(restOut).map { ProcessOutput.stdoutLine($0) }
            }
            if let tail = self.outFramer.flush() { trailing.append(.stdoutLine(tail)) }
            if let restErr, !restErr.isEmpty {
                trailing += self.errFramer.append(restErr).map { ProcessOutput.stderrLine($0) }
            }
            if let tail = self.errFramer.flush() { trailing.append(.stderrLine(tail)) }
            self.lock.unlock()
            for t in trailing { self.emit(t) }
            self.emit(.exited(status: proc.terminationStatus,
                              signaled: proc.terminationReason == .uncaughtSignal))
            self.finish()
        }

        do {
            try process.run()
            processIdentifier = process.processIdentifier
            launchedStart = ProcessTree.startTime(of: processIdentifier)
        } catch {
            emit(.launchFailed(error.localizedDescription))
            finish()
        }
    }

    var isRunning: Bool { process.isRunning }

    /// 끝난 프로세스의 종료 코드. 실행하지 못했거나 아직 실행 중이면 nil
    /// (`Process.terminationStatus` 는 그때 예외를 던지므로 먼저 확인한다).
    var terminationStatus: Int32? {
        guard processIdentifier > 0, !process.isRunning else { return nil }
        return process.terminationStatus
    }

    /// stdin 으로 한 줄(JSON) 을 보낸다. 파이프가 닫혀 있으면 false.
    @discardableResult
    func writeLine(_ line: String) -> Bool {
        lock.lock()
        let closed = stdinClosed
        lock.unlock()
        guard !closed, process.isRunning else { return false }
        guard var data = line.data(using: .utf8) else { return false }
        data.append(0x0A)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    func closeStdin() {
        lock.lock()
        guard !stdinClosed else { lock.unlock(); return }
        stdinClosed = true
        lock.unlock()
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// SIGTERM. 예의 있는 종료.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    /// SIGKILL. terminate 가 통하지 않을 때만.
    func kill() {
        guard process.isRunning, processIdentifier > 0 else { return }
        Foundation.kill(processIdentifier, SIGKILL)
    }

    /// 종료를 기다린다. 시간 안에 끝나지 않으면 false.
    /// 반환값이 false 면 "종료 확실성"을 주장하지 않는다.
    func waitForExit(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            // 부른 작업이 취소돼도 바쁘게 돌지 않는다 (종료 여부는 시간이 지나야 안다).
            await uncancellableSleep(nanoseconds: 40_000_000)
        }
        return !process.isRunning
    }

    /// terminate → 대기 → kill → 대기, 그다음 남은 자손(이 프로세스가 띄운 셸 · 개발 서버 · 하위 에이전트 · MCP 서버)도 같은 순서로.
    /// 최종적으로 프로세스와 자손이 모두 죽었는지 반환한다.
    ///
    /// 자손은 **끄기 전에** 모아 둔다 — 부모가 끝나면 launchd 로 넘어가 찾을 수 없다. 프로세스 그룹으로 보내지 않는 것은 Claude Code 가
    /// Bash 셸을 새 세션(새 그룹)으로 띄울 수 있어서다. 보통은 CLI 가 자기 자식을 정리하지만, 백그라운드 작업이 남은 채로 오류 · 한도로
    /// 끝나는 실행 · 중단이 응답하지 않는 실행 · 앱 종료에서는 남아 같은 폴더에서 계속 돌 수 있었다 (git · 인계 잠금이 보지 못했다).
    /// 이미 스스로 끝난 프로세스는 자손을 찾지 않는다 (그 PID 는 다른 프로세스의 것일 수 있다).
    @discardableResult
    func shutdown(graceSeconds: TimeInterval = 3, killGraceSeconds: TimeInterval = 2) async -> Bool {
        closeStdin()
        guard process.isRunning else { return true }
        let descendants: [ProcessTree.Member]
        if Self.cleansDescendants, processIdentifier > 0, let launchedStart,
           ProcessTree.startTime(of: processIdentifier) == launchedStart {
            descendants = ProcessTree.descendants(of: processIdentifier)
        } else {
            descendants = []
        }
        terminate()
        var exited = await waitForExit(timeout: graceSeconds)
        if !exited {
            kill()
            exited = await waitForExit(timeout: killGraceSeconds)
        }
        let survivors = await ProcessTree.terminate(descendants, grace: killGraceSeconds)
        return exited && survivors.isEmpty
    }
}

/// 자손 프로세스 찾기 · 끄기 (libproc). 앱이 띄운 프로세스의 자손만 — 이름으로 찾지 않고, 같은 사용자의 것만, 시작 시각으로 PID 재사용을
/// 거른다.
enum ProcessTree {
    /// 프로세스 하나 — PID 와 시작 시각(마이크로초). 같은 PID 라도 시작 시각이 다르면 다른 프로세스다.
    struct Member: Equatable, Sendable {
        let pid: pid_t
        let started: UInt64
    }

    /// 살아 있는(좀비가 아닌) 내 사용자의 프로세스면 시작 시각. 아니면 nil.
    static func startTime(of pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_status != 5 /* SZOMB — 끝났는데 거둬지지 않음 */ else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// 바로 아래 자식들의 PID.
    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while capacity <= 16_384 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { raw in
                Int(proc_listchildpids(pid, raw.baseAddress, Int32(raw.count)))
            }
            guard count > 0 else { return [] }
            if count < capacity { return buffer.prefix(count).filter { $0 > 0 } }
            capacity *= 4
        }
        return []
    }

    /// `root` 아래의 모든 자손 (root 는 빼고). 많아도 4096 개까지.
    static func descendants(of root: pid_t) -> [Member] {
        var result: [Member] = []
        var queue = [root]
        var seen: Set<pid_t> = [root]
        while let pid = queue.popLast(), result.count < 4096 {
            for child in children(of: pid) where seen.insert(child).inserted {
                guard let started = startTime(of: child) else { continue }
                result.append(Member(pid: child, started: started))
                queue.append(child)
            }
        }
        return result
    }

    /// 그 프로세스가 아직 (같은 프로세스로) 살아 있는지.
    static func isAlive(_ member: Member) -> Bool { startTime(of: member.pid) == member.started }

    /// SIGTERM → `grace` 초 → SIGKILL. 그래도 남은 것을 돌려준다.
    static func terminate(_ members: [Member], grace: TimeInterval) async -> [Member] {
        var alive = members.filter(isAlive)
        guard !alive.isEmpty else { return [] }
        for member in alive { _ = Darwin.kill(member.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            alive = alive.filter(isAlive)
            if alive.isEmpty { return [] }
            await uncancellableSleep(nanoseconds: 50_000_000)
        }
        for member in alive where isAlive(member) { _ = Darwin.kill(member.pid, SIGKILL) }
        for _ in 0..<10 {
            alive = alive.filter(isAlive)
            if alive.isEmpty { return [] }
            await uncancellableSleep(nanoseconds: 50_000_000)
        }
        return alive
    }
}
