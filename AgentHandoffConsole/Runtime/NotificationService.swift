import Foundation
import UserNotifications

/// 시스템 알림을 낼지의 순수 판정 (H15 · chat-15 · nav-6). `NotificationService.post` 와 시험이 함께 쓴다.
enum NotificationGate {
    enum Decision: Equatable, Sendable {
        /// 지금 보낸다.
        case deliver
        /// 권한을 먼저 묻고, 허용되면 보낸다 — 앱이 뒤에 있을 때 처음 알릴 일이 생긴 순간 (이번 실행에서 한 번).
        case askThenDeliver
        /// 내지 않는다.
        case skip(Reason)
    }

    enum Reason: Equatable, Sendable {
        /// 설정에서 껐거나 알림 센터를 쓸 수 없다.
        case disabled
        /// 앱이 앞에 있고 그 대화가 칸에 보인다 — 칸 머리 · 승인 카드 · Dock 배지로 충분하다.
        case onScreen
        /// 권한이 없다 (거부 · 묻지 않았는데 앱이 앞에 있다 · 이번 실행에서 이미 물었다).
        case notAuthorized
    }

    /// `authorized` 는 권한(허용 true · 거부 false · 묻지 않음/모름 nil), `canAsk` 는 이번 실행에서 아직 묻지 않았고 실제 실행인가.
    static func decide(enabled: Bool, authorized: Bool?, canAsk: Bool, appActive: Bool, threadOnScreen: Bool) -> Decision {
        guard enabled else { return .skip(.disabled) }
        if appActive && threadOnScreen { return .skip(.onScreen) }
        if authorized == true { return .deliver }
        // 묻지 않았으면 앱이 뒤에 있을 때만 묻는다 — 앞에 있으면 알림 없이도 보인다 (Dock 배지 · 칸 머리 · "응답 필요").
        // 작업 도중 앱을 보고 있는 사람 앞에 권한 창을 예고 없이 띄우지 않는다.
        if authorized == nil, canAsk, !appActive { return .askThenDeliver }
        return .skip(.notAuthorized)
    }

    /// 이번 실행에서 권한을 물은 일의 한 줄 (점검표 ② · 설정 > 일반) — 언제 · 왜 물었고 · 어떻게 됐나 (H15: 답한 적 없는데 "꺼짐" 인지,
    /// 요청이 실패했는지 가르게). 물은 적이 없거나 허용됐으면 nil. 시각은 `clock`(예: "14:05")으로.
    static func requestNote(_ request: NotificationService.PermissionRequest?, clock: (Date) -> String) -> String? {
        guard let request else { return nil }
        let time: String = clock(request.askedAt)
        var cause: String = "\(time) 에 [알림 허용] 으로 macOS 가 알림 허용을 물었습니다"
        if request.trigger == .firstAlert { cause = "\(time) 에 처음 알릴 일이 생겨 macOS 가 알림 허용을 물었습니다" }
        switch request.outcome {
        case .granted: return nil
        case .pending: return cause + " — 화면 오른쪽 위의 알림에서 답하세요."
        case .denied: return cause + ". 허용되지 않아 알림이 꺼져 있습니다 — 시스템 설정 > 알림에서 켤 수 있습니다."
        case .failed(let message): return cause + ". 요청이 실패했습니다 (\(message))."
        }
    }

    /// 알림에 싣는 글(제목 · 본문)의 비밀값을 가린다 (`SecretMasker.mask`, 최선 노력). 알림 센터는 지난 알림을 남기고 앱이 뒤에
    /// 있어도 배너로 보인다 — Codex 의 명령 승인은 명령 원문(`PGPASSWORD=… psql` · `curl -H 'Authorization: Bearer …'`)이 본문이다.
    /// 줄 맨 앞의 `KEY=…` 는 줄 끝까지 가린다 (명령 전체는 앱의 승인 카드에 있다). `NotificationService.post` 가 모든 알림에 쓴다.
    static func redacted(_ text: String) -> String { SecretMasker.mask(text) }
}

/// 선택적 macOS 알림.
/// 권한이 없거나 알림 시스템을 쓸 수 없어도 앱 기능은 정상 작동해야 한다.
@MainActor
@Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// nil = 아직 확인하지 않음.
    private(set) var authorized: Bool?
    /// 권한 상태 (점검표의 ② 알림). 처음 읽기 전에는 `checking`, 읽지 못했으면 `unknown` — `readSettings` 가 채운다.
    private(set) var permission: NotificationPermission = .checking
    /// 알림 설정의 "앱 아이콘 배지" (Dock 배지가 이것을 따른다). nil 이면 모름.
    private(set) var badgesEnabled: Bool?
    /// 마지막 실패 (권한 요청 실패 · 알림 보내기 실패). 권한 요청이 허용 · 거부로 끝나면 지운다 — 거부는 `lastRequest` 가 말한다.
    private(set) var lastError: String?
    var enabled: Bool = true

    /// 이번 실행에서 권한을 물은 기록 — 언제 · 왜 물었고 · 어떻게 됐나. 점검표 · 설정이 "답한 적 없는데 꺼짐" 과 "요청 실패" 를
    /// 가를 수 있게 사실대로 보인다 (H15).
    struct PermissionRequest: Equatable, Sendable {
        enum Trigger: String, Sendable {
            /// 사람이 점검표 · 설정의 [알림 허용] 을 눌렀다.
            case button
            /// 앱이 뒤에 있을 때 처음 알릴 일(승인 · 작업 끝 · 한도)이 생겨 앱이 물었다.
            case firstAlert
        }
        enum Outcome: Equatable, Sendable {
            case pending, granted, denied
            case failed(String)
        }
        var trigger: Trigger
        var askedAt: Date
        var outcome: Outcome
    }
    private(set) var lastRequest: PermissionRequest?

    /// 이번 실행에서 권한을 물은 일의 한 줄 (`NotificationGate.requestNote`) — 점검표 ② · 설정 > 일반이 보인다.
    var requestNote: String? {
        NotificationGate.requestNote(lastRequest) { Self.clockFormatter.string(from: $0) }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    #if DEBUG
    /// 검증용: 최근 `post` 의 제목 · 본문(가린 뒤)과 판정 (50개까지) — 시험 실행에는 알림 센터가 없어 보낸 것을 볼 수 없다.
    struct PostRecord: Sendable {
        var title: String
        var body: String = ""
        var decision: NotificationGate.Decision
    }
    @ObservationIgnored private(set) var postLog: [PostRecord] = []
    #endif

    /// 앱이 앞에 있는가 · 그 대화가 메인 창의 칸에 보이는가 — 앱 층이 넣는다 (`AppDelegate`, AppKit 을 모르는 이 파일은 묻지 못한다).
    /// 기본은 "뒤에 있다 · 보이지 않는다" (검증 하네스 · 화면 확인용 실행).
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { false }
    @ObservationIgnored var isThreadOnScreen: @MainActor (String) -> Bool = { _ in false }

    /// 알림을 눌렀을 때 이동할 대상.
    var pendingThreadID: String?
    var pendingOpensHandoff = false
    /// 자동 인계 알림의 취소·검토. 메인 창이 닫혀 있어도 처리돼야 하므로
    /// 화면을 거치지 않고 모델이 직접 받는다.
    /// 두 번째 인수는 그 알림의 대화 ID — 자동 인계는 대화마다 따로 돈다.
    @ObservationIgnored var automaticActionHandler: (@MainActor (AutomaticAction, String?) -> Void)?

    private var centerAvailable = true
    /// `bootstrap` 을 거친 실제 실행인지 (화면 확인용 실행 · 검증 하네스는 권한을 묻지 않는다).
    private var bootstrapped = false
    /// 이번 실행에서 권한을 한 번 물었다 — 거절한 사람에게 알림마다 다시 묻지 않는다.
    private var askedThisLaunch = false
    /// 권한을 묻게 한 알림은 이 안에 허용됐을 때만 보낸다 (초).
    static let lateAuthorizationLimit: TimeInterval = 15

    override init() {
        super.init()
    }

    private var center: UNUserNotificationCenter? {
        guard centerAvailable else { return nil }
        // 번들이 제대로 구성되지 않은 상태(예: 스크립트 실행)에서는 예외가 날 수 있다.
        guard Bundle.main.bundleIdentifier != nil else {
            centerAvailable = false
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    func bootstrap() {
        guard let center else {
            authorized = false
            lastError = "알림 센터를 사용할 수 없습니다. (번들 식별자 없음)"
            return
        }
        bootstrapped = true
        center.delegate = self
        let cancel = UNNotificationAction(identifier: AutomaticAction.cancel.rawValue,
                                          title: "자동 인계 취소")
        let review = UNNotificationAction(identifier: AutomaticAction.review.rawValue,
                                          title: "검토", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.automaticHandoff.rawValue,
                                   actions: [cancel, review], intentIdentifiers: [])
        ])
        Task { await readSettings() }
    }

    /// 권한 상태 · 배지 설정을 읽는다 (부트스트랩과 따로 — 점검표의 "다시 확인" · 앱이 다시 앞에 올 때). 권한을 묻지는 않는다.
    /// 화면 확인용 실행(`AHC_OFFLINE`)에서는 부르지 않는다 — 부르는 쪽(`AppModel+Setup`)이 막는다.
    @discardableResult
    func readSettings() async -> (permission: NotificationPermission, badges: Bool?) {
        guard let center else {
            permission = .unknown
            badgesEnabled = nil
            return (.unknown, nil)
        }
        let settings = await center.notificationSettings()
        let read: NotificationPermission
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: read = .authorized
        case .denied: read = .denied
        case .notDetermined: read = .notDetermined
        @unknown default: read = .unknown
        }
        let badges: Bool?
        switch settings.badgeSetting {
        case .enabled: badges = true
        case .disabled: badges = false
        default: badges = nil
        }
        permission = read
        badgesEnabled = badges
        switch read {
        case .authorized: authorized = true
        case .denied: authorized = false
        case .notDetermined, .unknown, .checking: authorized = nil
        }
        return (read, badges)
    }

    func requestAuthorization(trigger: PermissionRequest.Trigger) async {
        guard let center else { return }
        askedThisLaunch = true
        lastRequest = PermissionRequest(trigger: trigger, askedAt: Date(), outcome: .pending)
        do {
            // 배지도 묻는다 — Dock 배지(사람을 기다리는 대화 수)가 알림 설정의 "앱 아이콘 배지" 를 따를 수 있다.
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorized = granted
            lastError = nil
            lastRequest?.outcome = granted ? .granted : .denied
        } catch {
            // 요청 하나의 실패로 알림 센터를 영영 끄지 않는다 — 상태는 다시 읽어 둔다 (점검표가 "다시 확인" 할 수 있게).
            // 실패해도 macOS 가 "꺼짐" 으로 남길 수 있다 (서명되지 않은 빌드 등 — 미실측) — 그래서 실패를 따로 남긴다.
            let message = "알림 권한 요청 실패: \(error.localizedDescription)"
            lastError = message
            lastRequest?.outcome = .failed(message)
        }
        await readSettings()
    }

    enum Category: String {
        case runFinished = "run_finished"
        case approvalNeeded = "approval_needed"
        case limitReached = "limit_reached"
        case automaticHandoff = "automatic_handoff"
    }

    enum AutomaticAction: String {
        case cancel = "automatic_handoff_cancel"
        case review = "automatic_handoff_review"
    }

    /// 알림을 보낸다 (`NotificationGate.decide`). 앱이 앞에 있고 그 대화가 칸에 보이면 내지 않는다 — 칸 머리 · 승인 카드 · Dock 배지가
    /// 이미 보인다. 권한을 아직 묻지 않았으면(알림 스위치는 기본 켜짐) **앱이 뒤에 있을 때** 처음 알릴 일이 생긴 이 순간 한 번 묻고,
    /// 허용되면 이 알림부터 보낸다. 묻지 않으면 새 사용자는 승인 필요 · 완료 알림을 하나도 받지 못하고 그 사실도 모른다.
    /// 제목 · 본문은 비밀값을 가린 뒤에 싣는다 (`NotificationGate.redacted`) — 모든 알림이 여기를 지난다.
    /// 돌려준 값은 판정 (시험이 본다).
    @discardableResult
    func post(category: Category, title rawTitle: String, body rawBody: String,
              threadID: String?, opensHandoff: Bool = false) -> NotificationGate.Decision {
        let title: String = NotificationGate.redacted(rawTitle)
        let body: String = NotificationGate.redacted(rawBody)
        let available: Bool = enabled && center != nil
        let canAsk: Bool = bootstrapped && !askedThisLaunch
        let appActive: Bool = isAppActive()
        var onScreen = false
        if let threadID { onScreen = isThreadOnScreen(threadID) }
        let decision = NotificationGate.decide(enabled: available, authorized: authorized, canAsk: canAsk,
                                               appActive: appActive, threadOnScreen: onScreen)
        #if DEBUG
        postLog.append(PostRecord(title: title, body: body, decision: decision))
        if postLog.count > 50 { postLog.removeFirst(postLog.count - 50) }
        #endif
        switch decision {
        case .skip:
            break
        case .deliver:
            deliver(category: category, title: title, body: body, threadID: threadID, opensHandoff: opensHandoff)
        case .askThenDeliver:
            askedThisLaunch = true
            let asked = Date()
            Task {
                await requestAuthorization(trigger: .firstAlert)
                // 권한 창을 한참 뒤에 눌렀으면 이 알림은 이미 지난 일이다 (답한 승인 · 끝난 자동 인계의 취소 단추) — 보내지 않는다.
                // 그 사이 앱을 앞으로 가져와 그 대화를 보고 있어도 보내지 않는다.
                var nowOnScreen = false
                if let threadID { nowOnScreen = isAppActive() && isThreadOnScreen(threadID) }
                if authorized == true, Date().timeIntervalSince(asked) < Self.lateAuthorizationLimit, !nowOnScreen {
                    deliver(category: category, title: title, body: body, threadID: threadID, opensHandoff: opensHandoff)
                }
            }
        }
        return decision
    }

    private func deliver(category: Category, title: String, body: String,
                         threadID: String?, opensHandoff: Bool) {
        guard enabled, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = category == .approvalNeeded ? .default : nil
        content.categoryIdentifier = category.rawValue
        var info: [String: Any] = ["category": category.rawValue]
        if let threadID { info["threadID"] = threadID }
        if opensHandoff { info["opensHandoff"] = true }
        content.userInfo = info

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = "알림을 보내지 못했습니다: \(error.localizedDescription)" }
        }
    }

    // 앱이 앞에 있어도 배너를 보여준다 — 그 대화가 칸에 보이면 빼고 (`post` 가 이미 거르지만, 보낸 뒤 앱이 앞으로 온 사이에도).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let threadID: String? = notification.request.content.userInfo["threadID"] as? String
        guard let threadID else { return [.banner, .sound] }
        let onScreen: Bool = await MainActor.run { self.isThreadOnScreen(threadID) }
        return onScreen ? [] : [.banner, .sound]
    }

    /// 알림을 누르면 관련 스레드로 이동한다.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let threadID = info["threadID"] as? String
        let opensHandoff = info["opensHandoff"] as? Bool ?? false
        // 자동 인계 알림 본문을 누른 것도 카운트다운을 멈추고 검토하겠다는 뜻으로 본다.
        let action: AutomaticAction?
        if info["category"] as? String == Category.automaticHandoff.rawValue {
            action = AutomaticAction(rawValue: response.actionIdentifier)
                ?? (response.actionIdentifier == UNNotificationDefaultActionIdentifier ? .review : nil)
        } else {
            action = nil
        }
        await MainActor.run {
            if let action { self.automaticActionHandler?(action, threadID) }
            // 취소는 알림에서 끝나는 동작이라 창을 앞으로 가져오지 않는다.
            guard action != .cancel else { return }
            self.pendingThreadID = threadID
            self.pendingOpensHandoff = opensHandoff
            NotificationCenter.default.post(name: .handoffConsoleOpenMainWindow, object: nil)
        }
    }
}

extension Notification.Name {
    static let handoffConsoleOpenMainWindow = Notification.Name("handoffConsoleOpenMainWindow")
    static let handoffConsoleOpenHandoff = Notification.Name("handoffConsoleOpenHandoff")
}
