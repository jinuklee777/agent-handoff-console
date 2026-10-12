import SwiftUI

/// 설정 창의 탭. 저장값(`settings.tab`)은 영어 식별자다 — 다른 화면이 탭을 골라 열 때(`select`) 같은 키를 쓴다.
enum SettingsTab: String, CaseIterable {
    case general, agents, handoff, automation, advanced, about

    static let storageKey = "settings.tab"

    /// 다음에 보일 탭을 정한다 (설정 창이 열려 있으면 곧바로 바뀐다). 여는 쪽은 그 뒤에 `openSettings()` 를 부른다.
    static func select(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
    }

    /// 자동 작업 탭은 실험 기능을 켰을 때만 있다 — 꺼졌으면 그 탭을 켜는 곳(고급)을 보인다.
    static func shown(_ stored: SettingsTab, automation: Bool) -> SettingsTab {
        stored == .automation && !automation ? .advanced : stored
    }
}

/// 설정 창 (⌘,): 일반 · 에이전트 · 인계 · (자동 작업 — 고급 > 실험 기능을 켰을 때만) · 고급 · 정보.
/// 프로젝트마다 다른 설정(Antigravity 허용 · Gemini 전송 · 작업 폴더 준비 명령 · 자동 작업 검증 명령)은 여기 없고
/// 사이드바의 프로젝트 메뉴 > "프로젝트 설정…"(`ProjectSettingsSheet`)에 있다. 저장 키는 예전 그대로다.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsTab.storageKey) private var stored: SettingsTab = .general

    var body: some View {
        let automation = model.orchestrationSettings.enabled
        TabView(selection: Binding(get: { SettingsTab.shown(stored, automation: automation) },
                                   set: { stored = $0 })) {
            GeneralSettingsTab()
                .tabItem { Label("일반", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AgentSettingsTab()
                .tabItem { Label("에이전트", systemImage: "cpu") }
                .tag(SettingsTab.agents)
            HandoffSettingsTab()
                .tabItem { Label("인계", systemImage: "arrow.left.arrow.right") }
                .tag(SettingsTab.handoff)
            if automation {
                OrchestrationSettingsTab()
                    .tabItem { Label("자동 작업", systemImage: "arrow.triangle.branch") }
                    .tag(SettingsTab.automation)
            }
            AdvancedSettingsTab()
                .tabItem { Label("고급", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advanced)
            AboutSettingsTab()
                .tabItem { Label("정보", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 680, height: Self.height)
        // 자동 작업을 끄면 그 탭에 머물던 저장값을 고급으로 — 다시 켰을 때 저절로 그 탭으로 넘어가지 않게.
        .onChange(of: automation) { _, on in
            if !on, stored == .automation { stored = .advanced }
        }
    }

    private static var height: CGFloat {
        #if DEBUG
        // 화면 확인용: `-preview.settingsHeight 1400` (긴 탭을 한 장에 찍을 때 — `ContentView` 의 `-preview.settings`).
        let preview = UserDefaults.standard.double(forKey: "preview.settingsHeight")
        if AppModel.offlinePreview, preview > 0 { return preview }
        #endif
        return 640
    }
}
