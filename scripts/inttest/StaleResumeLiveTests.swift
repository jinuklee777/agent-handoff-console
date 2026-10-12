import Foundation
import ImageIO

// MARK: - 실측: 이어받은 세션에 남은 작업 알림 (`inttest staleresume`)

/// 전 실행의 백그라운드 작업이 남은 세션을 이어받으면 CLI 는 그 알림의 턴을 먼저 돌리고 result 를 낸다. 앱이 그 result 에서
/// 끝내면 우리 메시지가 처리되지 않고 버려진다 (2026-09-29 — 사진을 붙인 메시지가 사라졌다). 실제 `ClaudeAdapter` 로:
///   1. 백그라운드 명령(`sleep 4`)을 띄운 실행을 첫 result 에서 끝낸다 (기다리지 않는 턴 — 작업이 세션에 남는다)
///   2. 그 세션을 이어받아 "HELLO" 를 부탁한다 → 우리 답으로 끝나야 한다
/// **실제 claude CLI 를 부르고 구독 한도를 쓴다** (haiku, 짧은 두 턴). `live` · `all` 에는 넣지 않았다.
@MainActor
enum StaleResumeLiveTests {
    static func run(_ t: TestKit) async {
        await t.group("실측: 이어받은 세션의 남은 작업 알림")
        let cli = await TestEnv.resolveCLI()
        guard let claude = cli.claude else {
            await t.check("claude CLI 실행 파일 탐색", false, "없음")
            return
        }
        let folder: URL
        do { folder = try TestEnv.makeTempProject("stale-resume") } catch {
            await t.check("임시 프로젝트", false, "\(error)")
            return
        }
        print("임시 테스트 프로젝트: \(folder.path)")

        let first = await turn(claude, env: cli.env, folder: folder, resume: nil, wait: false,
                               prompt: "Use the Bash tool with run_in_background set to true to run exactly: sleep 4; echo done. "
                                   + "Do not wait for it. Then reply with the single word: started")
        guard let sessionID = first.result?.sessionID else {
            await t.check("첫 실행 (백그라운드 명령)", false, String(describing: first.result))
            return
        }
        await t.check("첫 실행은 첫 result 에서 끝남 (작업은 세션에 남는다)", first.result?.state == .completed,
                      String(describing: first.result?.state))
        try? await Task.sleep(for: .seconds(6))

        let second = await turn(claude, env: cli.env, folder: folder, resume: sessionID, wait: true,
                                prompt: "Reply with exactly: HELLO")
        await t.check("이어받은 실행: 남은 알림의 턴이 아니라 우리 답으로 끝난다",
                      second.result?.state == .completed && (second.result?.resultText ?? "").contains("HELLO"),
                      "state=\(String(describing: second.result?.state)) text=\(second.result?.resultText ?? "nil")")
        await t.check("남은 알림을 먼저 처리한다고 안내한다", second.notices.contains { $0.contains("남아 있던") },
                      second.notices.joined(separator: " | "))

        // 사진을 붙인 메시지 (같은 세션을 이어받아): 앱이 저장하는 모양 그대로 보낸다.
        do {
            let image = try redSquare(in: folder)
            let third = await turn(claude, env: cli.env, folder: folder, resume: sessionID, wait: true,
                                   prompt: "What is the main color of the attached image? Answer with one lowercase English word.",
                                   images: [image])
            await t.check("이미지를 붙인 메시지: 모델이 이미지를 본다", (third.result?.resultText ?? "").lowercased().contains("red"),
                          third.result?.resultText ?? "nil")
        } catch {
            await t.check("이미지 준비", false, "\(error)")
        }
    }

    /// 빨간 사각형 PNG 를 앱과 같은 길(`ImageAttachments.importData`)로 저장한다.
    private static func redSquare(in folder: URL) throws -> ImageAttachment {
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageAttachments.ImportError.unreadable("red")
        }
        context.setFillColor(CGColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let cg = context.makeImage() else { throw ImageAttachments.ImportError.unreadable("red") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ImageAttachments.ImportError.unreadable("red")
        }
        CGImageDestinationAddImage(destination, cg, nil)
        CGImageDestinationFinalize(destination)
        return try ImageAttachments.importData(data as Data, name: "red.png", into: folder.appendingPathComponent("attachments"))
    }

    private struct Outcome {
        var result: AgentTurnResult?
        var notices: [String] = []
    }

    private static func turn(_ claude: String, env: [String: String], folder: URL, resume: String?, wait: Bool,
                             prompt: String, images: [ImageAttachment] = []) async -> Outcome {
        let adapter = ClaudeAdapter(executablePath: claude, environment: env)
        let request = AgentTurnRequest(runID: UUID().uuidString, prompt: prompt, workingDirectory: folder,
                                       resumeSessionID: resume, model: "haiku", waitForBackground: wait,
                                       images: images)
        var outcome = Outcome()
        for await event in adapter.start(request) {
            switch event {
            case .approvalRequested(let approval):
                await adapter.respond(approvalID: approval.id, decision: .allow)
            case .notice(let text):
                outcome.notices.append(text)
            case .finished(let result):
                outcome.result = result
            default:
                break
            }
        }
        return outcome
    }
}
