import Foundation

// MARK: - 프로세스 끄기: 자손까지

/// `ManagedProcess.shutdown` 이 띄운 프로세스의 자손(백그라운드 셸 · 손자 · 새 세션으로 떨어져 나간 프로세스)까지 끈다.
/// 예전에는 직접 띄운 PID 만 기다려, 셸이 띄운 `sleep` 같은 자손이 launchd 로 넘어가 계속 돌았다 — 실행이 끝난 뒤에도 같은 폴더에서
/// 개발 서버가 돌면 git · 인계 잠금이 보지 못했다.
enum ProcessTreeTests {
    static func run(_ t: TestKit) async {
        await t.group("프로세스 끄기: 자손(백그라운드 · 손자 · 새 세션)까지")
        // 셸 → 백그라운드 sleep 둘, 셸 → 하위 셸 → sleep(손자), perl 로 새 세션을 만든 sleep (Claude 가 Bash 셸을 새 세션으로 띄우는 것과 같은 꼴).
        var script = "sleep 300 & sleep 300 & sh -c 'sleep 300 & wait' & "
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") {
            script += "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); exec \"sleep\", \"300\"' & "
        }
        script += "wait"
        let proc = ManagedProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                  workingDirectory: nil, environment: ["PATH": "/usr/bin:/bin"])
        let stream = proc.makeStream()
        let drain = Task { for await _ in stream {} }
        proc.launch()
        // 자손이 다 뜰 때까지 (최대 3초).
        var members: [ProcessTree.Member] = []
        let expected = FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") ? 5 : 4
        for _ in 0..<60 {
            members = ProcessTree.descendants(of: proc.processIdentifier)
            if members.count >= expected { break }
            await uncancellableSleep(nanoseconds: 50_000_000)
        }
        await t.check("자손을 찾는다 (백그라운드 · 하위 셸 · 손자 · 새 세션)", members.count >= expected, "\(members.count)개")
        let ok = await proc.shutdown(graceSeconds: 1, killGraceSeconds: 1)
        let survivors = members.filter(ProcessTree.isAlive)
        await t.check("끄면 자손도 모두 끝난다", ok && survivors.isEmpty, "남은 것 \(survivors.map(\.pid))")
        drain.cancel()

        // 이미 스스로 끝난 프로세스는 자손을 찾지 않는다 (그 PID 는 다른 프로세스의 것일 수 있다).
        let quick = ManagedProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], workingDirectory: nil,
                                   environment: [:])
        let quickStream = quick.makeStream()
        quick.launch()
        for await _ in quickStream {}
        await t.check("스스로 끝난 프로세스의 끄기는 곧바로 성공", await quick.shutdown())
        await t.check("내 프로세스가 아니거나 없는 PID 는 시작 시각이 없다",
                      ProcessTree.startTime(of: 1) == nil && ProcessTree.startTime(of: 0) == nil)
    }
}
