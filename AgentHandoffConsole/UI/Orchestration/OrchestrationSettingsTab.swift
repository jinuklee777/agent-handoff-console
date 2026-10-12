import SwiftUI

/// 설정 > 자동 작업 — 고급 > 실험 기능에서 켰을 때만 보이는 탭. 값은 `OrchestrationSettings` 하나이고, 바꿀 때마다 통째로 저장한다.
/// 프로젝트마다의 검증 명령은 프로젝트 설정(`ProjectSettingsSheet`)에 있다.
struct OrchestrationSettingsTab: View {
    @Environment(AppModel.self) private var model

    @State private var stats: [ProfileStats] = []
    @State private var profilesExpanded = false
    /// 지우기 · 기본값으로 되돌리기는 한 번 더 묻는다 (set-22 — 잘못 누르면 확인 없이 프로필이 지워지거나 모두 초기화됐다).
    @State private var deletingProfile: ExecutionProfile?
    @State private var confirmingReset = false

    private var settings: OrchestrationSettings { model.orchestrationSettings }

    private func update(_ change: (inout OrchestrationSettings) -> Void) {
        var next = model.orchestrationSettings
        change(&next)
        model.saveOrchestrationSettings(next)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<OrchestrationSettings, T>) -> Binding<T> {
        Binding(get: { model.orchestrationSettings[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 10) {
                    SettingsTag(text: "실험")
                    Text("실험 기능입니다. 동작과 설정이 바뀔 수 있습니다. 끄면 이 탭과 입력창의 ‘자동’이 사라집니다.")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("끄기") { update { $0.enabled = false } }
                }
            }

            Section {
                SettingsToggleRow(title: "계획을 보여 준 뒤 시작",
                                  subtitle: "계획을 확인하고 [시작]을 누를 때 실행합니다. 끄면 계획이 서는 대로 바로 시작합니다.",
                                  help: Self.startHelp,
                                  isOn: binding(\.requiresPlanApproval))
            } header: {
                Text("시작")
            }

            Section {
                Picker(selection: binding(\.reviewMode)) {
                    ForEach(ReviewMode.allCases, id: \.self) { Text($0.koreanName).tag($0) }
                } label: {
                    SettingsLabel(title: "검토 에이전트", subtitle: "작업이 끝날 때마다 읽기 전용으로 완료 조건을 하나씩 확인합니다.")
                }
                Picker(selection: binding(\.reviewPanel)) {
                    ForEach(ReviewPanelMode.allCases, id: \.self) { Text($0.koreanName).tag($0) }
                } label: {
                    SettingsLabel(title: "두 명이 함께 검토",
                                  subtitle: "Claude 와 Codex 가 따로 검토해, 한 명이라도 실패면 실패로 봅니다. 검토가 늘어나는 만큼 한도를 더 씁니다.")
                }
                .disabled(settings.reviewMode == .never)
            } header: {
                Text("검증")
            } footer: {
                SettingsFooter("검증 명령(예: 테스트)은 프로젝트 설정(사이드바의 프로젝트 메뉴)에서 적습니다. 적어 둔 명령만 실행하고, "
                               + "명령도 검토도 없으면 통과로 치지 않고 멈춰서 묻습니다.")
            }

            Section {
                Picker("계획 담당", selection: binding(\.plannerProfileID)) {
                    ForEach(readOnlyProfiles) { Text($0.name).tag($0.id) }
                }
                Picker("검토 담당", selection: binding(\.reviewerProfileID)) {
                    ForEach(readOnlyProfiles) { Text($0.name).tag($0.id) }
                }
                DisclosureGroup(isExpanded: $profilesExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(settings.profiles) { profile in profileRow(profile) }
                        HStack {
                            Button("프로필 추가") {
                                update { $0.profiles.append(ExecutionProfile(id: UUID().uuidString, name: "새 프로필", provider: .claude, tier: 2)) }
                            }
                            Button("기본값으로 되돌리기…") { confirmingReset = true }
                            Spacer()
                        }
                        Text("계획 · 검토 담당은 파일을 바꾸지 못하게 돌릴 수 있는 Claude · Codex 만 고를 수 있습니다 (Antigravity 는 읽기 전용을 "
                             + "보장하지 못합니다). CLI 를 쓸 수 없거나 로그인 · 한도 여유가 확인되지 않은 프로필은 후보에서 빠지고, 그 까닭은 배정 기록에 남습니다.")
                            .font(Theme.ui(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 6)
                } label: {
                    HStack {
                        Text("실행 프로필 \(settings.profiles.count)개")
                        Spacer()
                        Text("모델 · 강도 · 등급").font(Theme.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                SettingsToggleRow(title: "한도 여유를 모르는 프로필도 쓰기",
                                  subtitle: "끄면 로그인과 한도 여유가 확인된 프로필에만 맡깁니다.",
                                  isOn: binding(\.allowUnknownLimits))
            } header: {
                Text("담당 배정")
            } footer: {
                SettingsFooter("쉬운 작업은 등급 1부터, 어려운 작업은 등급 3부터 맡깁니다. 검증에 실패하면 같은 담당이 한 번 보완하고, "
                               + "그래도 안 되면 더 높은 등급으로 넘깁니다 (작업당 3번까지).")
            }

            Section {
                if stats.isEmpty {
                    Text("아직 끝난 시도가 없습니다. 프로필마다 통과율이 여기에 쌓입니다.")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stats) { row in
                        HStack {
                            Text(settings.profiles.first { $0.id == row.profileID }?.name ?? row.profileID)
                            Spacer()
                            Text(statText(row)).font(Theme.ui(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("성과")
            } footer: {
                if !stats.isEmpty {
                    SettingsFooter("통과율의 분모에는 검증 실패만 넣습니다 (환경 · 한도 · 네트워크 문제와 검증 결과 미확인은 뺍니다). "
                                   + "쉬운 일이 낮은 등급에 먼저 가므로 프로필끼리 그대로 비교할 수 없습니다. 표본이 적을 때는 참고만 하세요.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let attempts = (try? await model.store.allOrchestrationAttempts()) ?? []
            let records = (try? await model.store.allVerificationRecords()) ?? []
            stats = OrchestrationMetrics.stats(attempts: attempts, verifications: records)
        }
        .alert(deletingTitle,
               isPresented: Binding<Bool>(get: { deletingProfile != nil }, set: { (shown: Bool) in if !shown { deletingProfile = nil } }),
               presenting: deletingProfile) { profile in
            Button("취소", role: .cancel) { deletingProfile = nil }
            Button("지우기", role: .destructive) {
                update { $0.profiles.removeAll { $0.id == profile.id } }
                deletingProfile = nil
            }
        } message: { profile in
            Text(profileRoleNote(profile) + "되돌릴 수 없습니다 — 필요하면 다시 추가하세요.")
        }
        .alert("실행 프로필을 기본값으로 되돌릴까요?", isPresented: $confirmingReset) {
            Button("취소", role: .cancel) {}
            Button("되돌리기", role: .destructive) { update { $0.profiles = ExecutionProfile.defaults } }
        } message: {
            Text("직접 고치거나 추가한 프로필 \(settings.profiles.count)개가 모두 처음 상태의 프로필로 바뀝니다.")
        }
    }

    /// 지우려는 프로필이 계획 · 검토 담당이면 그 사실을 먼저 적는다.
    private func profileRoleNote(_ profile: ExecutionProfile) -> String {
        var roles: [String] = []
        if settings.plannerProfileID == profile.id { roles.append("계획 담당") }
        if settings.reviewerProfileID == profile.id { roles.append("검토 담당") }
        return roles.isEmpty ? "" : "지금 \(roles.joined(separator: " · "))입니다 — 지운 뒤 다른 프로필을 고르세요. "
    }

    /// "계획을 보여 준 뒤 시작" 의 도움말 — 결과만 쉬운 말로 (예전에는 "실행 슬롯은 폴더마다 하나라서…" 같은 내부 구조를 적었다, txt-26).
    /// 같은 폴더의 다른 대화는 막지 않는다 — 자동 작업이 폴더가 빌 때까지 기다린다 (`AppModel.isRunSlotBusy`). 검토 중에는 그 폴더의
    /// 보내기를 막는다 (`AppModel.send` 의 검토 확인).
    private static let startHelp: String = [
        "입력창 에이전트 메뉴의 ‘자동’을 고르고 보내면 에이전트 하나에게 바로 가지 않고, 계획 담당이 하위 작업으로 나누고 작업마다 아래 프로필 하나를 배정해 하나씩 실행합니다.",
        "작업이 끝날 때마다 완료 조건으로 검증합니다.",
        "같은 폴더의 다른 대화에서 에이전트가 일하는 동안에는 자동 작업이 다음 하위 작업을 기다리고, 자동 작업의 검토가 도는 동안에는 그 폴더에서 새로 보낼 수 없습니다.",
    ].joined(separator: " ")

    private var deletingTitle: String {
        let name: String = deletingProfile?.name ?? ""
        return "‘\(name)’ 프로필을 지울까요?"
    }

    private var readOnlyProfiles: [ExecutionProfile] {
        settings.profiles.filter { $0.enabled && $0.provider.supportsReadOnlyTurns }
    }

    private func statText(_ row: ProfileStats) -> String {
        let rate = row.passRate.map { "통과율 \(Int(($0 * 100).rounded()))%" } ?? "통과율 —"
        return "\(rate) · 시도 \(row.attempts) (통과 \(row.passed), 그중 명령 검증 \(row.passedObjectively) · 검증 실패 \(row.failedCapability)"
            + " · 제외 \(row.excluded) · 미확인 \(row.unverified)) · 첫 시도 통과 \(row.firstTryPasses)/\(row.firstTries)"
    }

    private func profileRow(_ profile: ExecutionProfile) -> some View {
        func field<T>(_ keyPath: WritableKeyPath<ExecutionProfile, T>) -> Binding<T> {
            Binding(get: { settings.profiles.first { $0.id == profile.id }?[keyPath: keyPath] ?? profile[keyPath: keyPath] },
                    set: { value in update { s in
                        if let index = s.profiles.firstIndex(where: { $0.id == profile.id }) { s.profiles[index][keyPath: keyPath] = value }
                    } })
        }
        func optional(_ keyPath: WritableKeyPath<ExecutionProfile, String?>) -> Binding<String> {
            Binding(get: { field(keyPath).wrappedValue ?? "" }, set: { field(keyPath).wrappedValue = $0.isEmpty ? nil : $0 })
        }
        // 화면에는 이름을 숨기지만(칸이 좁다) VoiceOver 는 줄마다 "<프로필> 사용" 처럼 읽는다 (set-22 — 이름 없는 스위치 · 팝업이었다).
        let name: String = profile.name.isEmpty ? "이름 없는 프로필" : profile.name
        return HStack(spacing: 6) {
            Toggle("\(name) 사용", isOn: field(\.enabled)).labelsHidden()
                .help("끄면 이 프로필에는 맡기지 않습니다")
            TextField("이름", text: field(\.name)).frame(width: 110).labelsHidden()
                .accessibilityLabel("\(name) 프로필 이름")
            Picker("\(name) 에이전트", selection: field(\.provider)) {
                ForEach(AgentProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().frame(width: 104)
            TextField("모델 (비우면 CLI 기본)", text: optional(\.model))
                .labelsHidden()
                .accessibilityLabel("\(name) 모델")
                .help("CLI 에 넘기는 모델 이름입니다. Codex 의 gpt-*-sol 처럼 버전 자리에 * 를 쓰면 그 계열의 최신 모델을 씁니다 "
                      + "(새 버전이 나오면 따라갑니다). Claude 의 opus · sonnet 같은 별칭도 CLI 가 최신 모델로 풉니다.")
            TextField("강도", text: optional(\.effort)).frame(width: 64).labelsHidden()
                .accessibilityLabel("\(name) 추론 강도")
            Picker("\(name) 등급", selection: field(\.tier)) {
                ForEach(1...3, id: \.self) { Text("등급 \($0)").tag($0) }
            }
            .labelsHidden().frame(width: 78)
            Button { deletingProfile = profile } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("프로필 삭제")
                .accessibilityLabel("\(name) 프로필 삭제")
        }
    }
}
