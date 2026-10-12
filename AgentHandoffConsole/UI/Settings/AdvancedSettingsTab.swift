import SwiftUI
import AppKit

/// 설정 > 고급: 비용 표시(가격표 시트) · 독립 작업 폴더 위치 · 진단(CLI 확인 기록 시트) · 실험 기능(자동 작업 — 켜면 탭이 생긴다).
struct AdvancedSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var showingPrices = false
    @State private var showingLog = false
    /// 고른 독립 작업 폴더 위치를 받지 않은 까닭 (다음에 고르면 지운다).
    @State private var locationError: String?

    var body: some View {
        Form {
            Section {
                SettingsRow(title: "API 환산 가격표",
                            subtitle: "턴 바닥글과 에이전트 기록에 보이는 비용은 실제 청구액이 아니라, 공개 API 가격으로 환산한 비교용 값입니다.") {
                    Button("가격표 열기…") { showingPrices = true }
                }
            } header: {
                Text("비용 표시")
            }

            Section {
                // 위치를 바꿀 수 있다 — 새로 만드는 독립 작업 폴더부터 (set-17). 환경 변수 AHC_WORKTREES_DIR 가 있으면 그것이 먼저다.
                SettingsPathRow(title: "만드는 위치", url: Worktrees.baseDirectory())
                HStack(spacing: 8) {
                    Spacer()
                    if !model.worktreesDirectoryOverride.isEmpty {
                        Button("기본 위치로") { model.worktreesDirectoryOverride = "" }
                            .help("~/.agent-handoff-console/worktrees 에 만듭니다")
                    }
                    Button("위치 바꾸기…") {
                        if let chosen = SettingsActions.choose(directories: true,
                                                               message: "독립 작업 폴더를 만들 폴더를 고르세요. 새로 만드는 것부터 이곳에 둡니다.") {
                            // 프로젝트 저장소 안에 만들게 되는 곳(그 프로젝트 폴더 · 저장소들을 모아 둔 폴더)은 받지 않는다 (ws-2).
                            if let project = Worktrees.locationConflict(chosen, projectPaths: model.projects.map(\.path)) {
                                locationError = SettingsText.worktreeLocationConflict(chosen: chosen, project: project)
                            } else {
                                locationError = nil
                                model.worktreesDirectoryOverride = chosen
                            }
                        }
                    }
                    .disabled(ProcessInfo.processInfo.environment["AHC_WORKTREES_DIR"]?.isEmpty == false)
                }
                if let locationError {
                    SettingsWarning(text: locationError)
                }
            } header: {
                Text("독립 작업 폴더")
            } footer: {
                SettingsFooter(SettingsText.worktreeLocationNote)
            }

            Section {
                SettingsRow(title: "CLI 확인 기록",
                            subtitle: "앱이 각 CLI 의 버전과 기능을 확인한 기록입니다. 문제를 알릴 때 함께 붙여 주세요.") {
                    Button("기록 보기…") { showingLog = true }
                }
            } header: {
                Text("진단")
            }

            Section {
                SettingsToggleRow(title: "자동 작업",
                                  subtitle: "요청을 작은 작업으로 나눠 에이전트들에게 차례로 맡기고, 끝날 때마다 검증합니다. "
                                      + "켜면 입력창 에이전트 메뉴에 ‘자동’이, 설정에 ‘자동 작업’ 탭이 생깁니다.",
                                  tag: "실험",
                                  isOn: Binding(get: { model.orchestrationSettings.enabled }, set: { on in
                                      var next = model.orchestrationSettings
                                      next.enabled = on
                                      model.saveOrchestrationSettings(next)
                                  }))
            } header: {
                Text("실험 기능")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPrices) { PricingSheet().environment(model) }
        .sheet(isPresented: $showingLog) { VerificationLogSheet().environment(model) }
    }
}

/// 가격표 (예전의 가격표 탭). 공개 API 가격 기준의 환산값이다 — 구독 청구액이 아니다.
/// 직접 넣은 가격은 고치고 지울 수 있다 — 같은 모델의 공개 가격보다 먼저 쓰이므로, 틀린 값이 전적 · 바닥글 비용에 계속 쓰이지 않게
/// (set-18). 숫자 칸은 소수점 쉼표("1,25")도 받고(`PriceCatalog.parsePrice`), [추가]가 꺼진 까닭을 칸 아래에 적는다.
private struct PricingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PriceEntry] = []
    @State private var newModel = ""
    @State private var newProvider: AgentProvider = .codex
    @State private var newInput = ""
    @State private var newOutput = ""
    /// 고치는 중인 직접 넣은 가격 (없으면 새로 추가).
    @State private var editing: PriceEntry?
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API 환산 가격표").font(Theme.ui(.body, .semibold))
                Text("실제 청구액이 아니라 공개 API 가격으로 환산한 비교용 값입니다. Claude 는 CLI 가 비용을 알려 주면 그 값을 먼저 씁니다. "
                     + "가격을 모르는 모델은 ‘금액 미확인’으로 보이고, 0원으로 치지 않습니다.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Table(entries) {
                TableColumn("에이전트") { Text($0.provider.displayName) }.width(76)
                TableColumn("모델") { Text($0.model).font(Theme.mono(.caption)) }
                TableColumn("입력 $/M") { Text(String(format: "%.2f", $0.inputPerMTok)) }.width(64)
                TableColumn("출력 $/M") { Text(String(format: "%.2f", $0.outputPerMTok)) }.width(64)
                TableColumn("캐시 읽기 $/M") { Text(String(format: "%.3f", $0.cacheReadPerMTok)) }.width(84)
                TableColumn("출처 · 적용일") {
                    Text("\($0.source) · \($0.effectiveDate)").font(Theme.ui(.caption)).help($0.source)
                }
            }
            .frame(minHeight: 200)
            GroupBox(formTitle) {
                VStack(alignment: .leading, spacing: 8) {
                    let userEntries: [PriceEntry] = entries.filter { (entry: PriceEntry) -> Bool in entry.isUserEntered }
                    if !userEntries.isEmpty {
                        ForEach(userEntries) { entry in userRow(entry) }
                        Divider()
                    }
                    HStack {
                        Picker("에이전트", selection: $newProvider) {
                            ForEach(AgentProvider.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        TextField("모델 이름", text: $newModel).frame(width: 180)
                            .accessibilityLabel("모델 이름")
                        TextField("입력 $/M", text: $newInput).frame(width: 80)
                            .accessibilityLabel("입력 가격, 백만 토큰당 달러")
                        TextField("출력 $/M", text: $newOutput).frame(width: 80)
                            .accessibilityLabel("출력 가격, 백만 토큰당 달러")
                        Button(saveTitle) { Task { await save() } }
                            .disabled(problem != nil)
                        if editing != nil {
                            Button("취소") { clearForm() }
                        }
                    }
                    Text(formNote)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(formNoteColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let saveError {
                        Text(saveError).font(Theme.ui(.caption)).foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
            }
            HStack {
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
        .task { await load() }
    }

    private var formTitle: String { editing == nil ? "모델 가격 직접 넣기" : "직접 넣은 가격 고치기" }
    private var saveTitle: String { editing == nil ? "추가" : "저장" }
    /// 적기 시작했는데 [추가]가 꺼져 있으면 까닭이므로 진하게.
    private var formNoteColor: Color { formHasInput && problem != nil ? Theme.ink2 : Color.secondary }

    /// 직접 넣은 가격 한 줄의 값 — "입력 1.25 · 출력 10.00 $/M · 2026-10-04".
    private static func priceSummary(_ entry: PriceEntry) -> String {
        let input: String = String(format: "%.2f", entry.inputPerMTok)
        let output: String = String(format: "%.2f", entry.outputPerMTok)
        return "입력 \(input) · 출력 \(output) $/M · \(entry.effectiveDate)"
    }

    /// 직접 넣은 가격 한 줄 — 고치기 · 지우기.
    private func userRow(_ entry: PriceEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.provider.displayName).frame(width: 76, alignment: .leading)
            Text(entry.model).font(Theme.mono(.caption)).lineLimit(1).truncationMode(.middle)
            Text(Self.priceSummary(entry))
                .font(Theme.ui(.caption)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("고치기") { startEditing(entry) }
                .disabled(editing?.id == entry.id)
                .accessibilityLabel("\(entry.model) 가격 고치기")
            Button("지우기", role: .destructive) { Task { await delete(entry) } }
                .accessibilityLabel("\(entry.model) 가격 지우기")
        }
        .controlSize(.small)
    }

    private var problem: String? {
        PriceCatalog.userEntryProblem(model: newModel, input: newInput, output: newOutput)
    }

    private var formHasInput: Bool {
        let all: String = newModel + newInput + newOutput
        return !all.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 칸 아래의 글 — 적기 시작했는데 [추가]가 꺼져 있으면 그 까닭, 아니면 형식 · 셈하는 법.
    private var formNote: String {
        if formHasInput, let problem { return problem }
        return Self.formatNote
    }

    private static let formatNote: String = [
        "가격은 백만 토큰당 달러입니다 (예: 1.25 — 소수점은 쉼표로 적어도 됩니다).",
        "캐시 읽기는 입력 가격의 0.1배, 캐시 쓰기는 1.25배로 셈합니다.",
        "직접 넣은 가격은 같은 모델의 공개 가격보다 먼저 쓰입니다.",
    ].joined(separator: " ")

    private func load() async {
        entries = (try? await model.store.priceEntries()) ?? []
    }

    private func startEditing(_ entry: PriceEntry) {
        editing = entry
        newProvider = entry.provider
        newModel = entry.model
        newInput = String(entry.inputPerMTok)
        newOutput = String(entry.outputPerMTok)
        saveError = nil
    }

    private func clearForm() {
        editing = nil
        newModel = ""; newInput = ""; newOutput = ""
    }

    private func save() async {
        guard problem == nil, let input = PriceCatalog.parsePrice(newInput), let output = PriceCatalog.parsePrice(newOutput) else { return }
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let entry = PriceCatalog.userEntry(provider: newProvider, model: newModel, input: input, output: output, today: today)
        do {
            if let editing {
                try await model.store.replaceUserPrice(id: editing.id, with: entry)
            } else {
                try await model.store.upsertPrice(entry)
            }
            saveError = nil
            clearForm()
        } catch {
            saveError = "저장하지 못했습니다: \(error.localizedDescription)"
        }
        await reloadPrices()
    }

    private func delete(_ entry: PriceEntry) async {
        do {
            try await model.store.deleteUserPrice(id: entry.id)
            if editing?.id == entry.id { clearForm() }
            saveError = nil
        } catch {
            saveError = "지우지 못했습니다: \(error.localizedDescription)"
        }
        await reloadPrices()
    }

    /// 실행기 · 검토 레인이 새 가격표로 셈하게 하고 목록을 다시 읽는다.
    private func reloadPrices() async {
        await model.runner.loadPrices()
        await model.reviewLanes.loadPrices()
        await load()
    }
}

/// CLI 확인 기록 — 처음 확인 · 버전이나 경로가 바뀌었을 때 · "다시 확인" 에서 남는다 (`AppModel.refreshAgentFacts`).
private struct VerificationLogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLI 확인 기록").font(Theme.ui(.body, .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if lines.isEmpty {
                        Text("아직 기록이 없습니다.").font(Theme.ui(.caption)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.mono(.caption)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
            HStack {
                Button(copied ? "복사함" : "모두 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(([AppVersion.report] + lines).joined(separator: "\n"), forType: .string)
                    copied = true
                }
                .disabled(lines.isEmpty)
                .help("앱 · macOS 버전과 함께 복사합니다")
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 440)
        .task {
            let records = (try? await model.store.verifications()) ?? []
            lines = records.map {
                "\(Fmt.dateTime.string(from: $0.at)) · \($0.provider) \($0.version) · \($0.capability) · \($0.result)"
            }
        }
    }
}
