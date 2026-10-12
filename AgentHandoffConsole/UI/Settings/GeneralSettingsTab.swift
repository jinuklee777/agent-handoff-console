import SwiftUI
import AppKit

/// 설정 > 일반: 알림 · 앱 열기와 닫기 · 메뉴바에 보일 한도 · 소리 · 대화 기록.
struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                SettingsToggleRow(title: "알림 받기", subtitle: SettingsText.notificationsNote,
                                  isOn: $model.notificationsEnabled)
                SettingsRow(title: "macOS 알림 권한") { permission }
                // 이번 실행에서 권한을 물은 일 · 요청 실패를 사실대로 — 점검표 ② 와 같은 줄 (H15).
                if let fact = model.notifications.requestNote ?? model.notifications.lastError {
                    Text(fact)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("알림")
            } footer: {
                SettingsFooter("알림을 꺼 두어도 앱은 그대로 씁니다. Dock 아이콘의 숫자 배지는 시스템 설정 > 알림에서 켜고 끕니다.")
            }

            Section {
                // 앱은 로그인 항목에 스스로 넣지 않는다 — 단추는 시스템 설정을 열기만 한다 (set-3 · txt-13).
                SettingsRow(title: "Mac 에 로그인하면 열기", subtitle: SettingsText.loginItemsNote) {
                    Button("로그인 항목 열기…") { SettingsActions.openLoginItems() }
                }
            } header: {
                Text("앱 열기와 닫기")
            } footer: {
                SettingsFooter("창을 닫아도 앱은 메뉴바에 남아 하던 작업을 계속합니다. 완전히 끄려면 ⌘Q 를 누르세요.")
            }

            Section {
                // 메뉴바 팝오버와 같은 목록 (`AppModel.limitEntries`) — 구간은 한도를 한 번 읽은 뒤에 생긴다.
                let entries = model.limitEntries
                if entries.isEmpty {
                    Text("이 Mac 에서 찾은 에이전트가 없어 고를 한도가 없습니다.")
                        .font(Theme.ui(.caption)).foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    menuBarEntryRow(entry)
                    ForEach(entry.snapshot.windows) { window in
                        menuBarWindowRow(entry, window)
                    }
                }
                if !model.menuBarHiddenLimits.isEmpty {
                    Button("모두 보이기") { model.menuBarHiddenLimits = [] }
                }
            } header: {
                Text("메뉴바에 보일 한도")
            } footer: {
                SettingsFooter(SettingsText.menuBarLimitsNote)
            }

            Section {
                SettingsToggleRow(title: SettingsText.effortSoundTitle, subtitle: SettingsText.effortSoundNote,
                                  isOn: $model.ultraSoundEnabled)
            } header: {
                Text("소리")
            }

            Section {
                SettingsRow(title: "다른 곳에서 쓰던 대화 가져오기",
                            subtitle: "이 Mac 에 남은 Claude Code · Codex 세션을 프로젝트별 대화로 옮깁니다. 같은 세션은 두 번 들어가지 않습니다.") {
                    Button("가져오기…") {
                        // 가져오기 시트는 메인 창에 뜬다 — 창이 닫혀 있으면 먼저 연다.
                        AppDelegate.showMainWindow()
                        model.showImportSheet = true
                    }
                }
                SettingsPathRow(title: "저장 위치", url: Store.defaultDatabaseURL())
                SettingsToggleRow(title: SettingsText.autoTitlesTitle, subtitle: SettingsText.autoTitlesNote,
                                  isOn: $model.autoThreadTitles)
            } header: {
                Text("대화 기록")
            } footer: {
                SettingsFooter("대화 기록과 설정은 이 Mac 에만 저장됩니다. 앱에는 따로 서버가 없습니다.")
            }
        }
        .formStyle(.grouped)
        .task {
            // 화면 확인용 실행(`AHC_OFFLINE`)은 알림 센터를 묻지 않는다 (`AppModel+Setup` 과 같은 규칙).
            guard !AppModel.offlinePreview else { return }
            await model.notifications.readSettings()
        }
    }

    @ViewBuilder
    private var permission: some View {
        switch model.notifications.permission {
        case .authorized:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.emerald)
                Text("허용됨").font(Theme.ui(.caption, .medium))
            }
        case .notDetermined:
            Button("허용하기") { Task { await model.requestNotificationPermission() } }
        case .denied:
            HStack(spacing: 8) {
                Text("꺼져 있음").font(Theme.ui(.caption)).foregroundStyle(.secondary)
                Button("시스템 설정 열기") { openNotificationSettings() }
            }
        case .unknown:
            Button("시스템 설정 열기") { openNotificationSettings() }
        case .checking:
            HStack(spacing: 6) {
                InkSpinner(color: Theme.slate)
                Text("확인 중").font(Theme.ui(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    /// 계정 한 줄 — 끄면 메뉴바에서 그 계정을 통째로 숨긴다.
    private func menuBarEntryRow(_ entry: LimitsPresentation.Entry) -> some View {
        let key = MenuBarLimits.entryKey(entry)
        let shown = !model.menuBarHiddenLimits.contains(key)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { shown }, set: { model.setMenuBarLimit(key, shown: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("\(entry.name) 메뉴바에 보이기")
            BrandMark(provider: entry.snapshot.provider, size: 13)
            Text(entry.name).lineLimit(1)
                .foregroundStyle(shown ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
            Spacer(minLength: 8)
            // 구간이 아직 없으면 그 까닭 (확인 전 · 읽지 못함) — 구간은 한도를 읽은 뒤에 고른다.
            if entry.snapshot.windows.isEmpty, let status = LimitsPresentation.shortStatus(entry.state) {
                Text(status).font(Theme.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// 구간 한 줄 (5시간 · 7일 · 모델 묶음) — 계정 줄 아래에 들여 쓴다. 계정을 껐으면 고를 수 없다.
    private func menuBarWindowRow(_ entry: LimitsPresentation.Entry, _ window: LimitWindow) -> some View {
        let key = MenuBarLimits.windowKey(entry, window)
        let entryShown = !model.menuBarHiddenLimits.contains(MenuBarLimits.entryKey(entry))
        let shown = entryShown && !model.menuBarHiddenLimits.contains(key)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { shown }, set: { model.setMenuBarLimit(key, shown: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("\(entry.name) \(window.label) 메뉴바에 보이기")
            Text(window.label).lineLimit(1)
                .foregroundStyle(shown ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
            Spacer(minLength: 8)
            Text(Fmt.percent(window.utilization))
                .font(Theme.digits(.caption)).foregroundStyle(.secondary)
        }
        .padding(.leading, 23)
        .disabled(!entryShown)
    }

    private func openNotificationSettings() {
        if let url = AppModel.notificationSettingsURL() { NSWorkspace.shared.open(url) }
    }
}
