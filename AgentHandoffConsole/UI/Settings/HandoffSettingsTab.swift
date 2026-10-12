import SwiftUI

/// 설정 > 인계: 인계가 무엇인지 · 사용 한도에 닿으면(알려 주기만 / 잠시 기다린 뒤 자동으로) · 이어 받을 순서 ·
/// 인계 문서 정리(앱이 정리 / Gemini 로 다듬기). 고른 쪽의 세부만 편다. 프로젝트마다의 Gemini 전송은 프로젝트 설정에 있다.
struct HandoffSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                explainer
            }

            Section {
                // 단추 이름은 대화의 한도 줄 · 입력창 메뉴와 같은 말 (`ContinueChoice.continueTitle`).
                SettingsChoiceRow(title: "알려 주기만",
                                  subtitle: "대화에 한도 안내와 이어 맡기기 단추(예: [\(ContinueChoice.continueTitle(name: "Codex"))])가 뜹니다. "
                                      + "넘길지는 인계 카드에서 직접 정합니다.",
                                  tag: "기본", selected: !model.automaticHandoffEnabled) {
                    model.automaticHandoffEnabled = false
                }
                SettingsChoiceRow(title: "잠시 기다린 뒤 자동으로 넘기기",
                                  subtitle: "인계 카드를 만들고, 카운트다운이 끝나면 사람이 확인하지 않아도 받는 에이전트(그 회사의 CLI)에게 "
                                      + "보냅니다. 그동안 멈추거나 취소하고 문서를 고칠 수 있습니다.",
                                  selected: model.automaticHandoffEnabled) {
                    model.automaticHandoffEnabled = true
                }
                if model.automaticHandoffEnabled {
                    SettingsRow(title: "취소할 시간",
                                subtitle: "넘기기 어려운 상황이면 보내지 않고 카드를 열어 둡니다 — 승인을 기다리는 중, 카드를 만든 뒤 새 입력이 있음, "
                                    + "받는 쪽 한도를 모름 같은 때입니다.",
                                help: "끝나지 않은 프로세스, 승인 · 질문 대기, 다른 실행 진행 중, 초안 이후 새 입력, 이전 인계가 전달됐는지 모름, "
                                    + "받는 쪽 한도 정보 없음, 다음 할 일 없음, Gemini 정리본의 검증 경고 — 하나라도 있으면 자동으로 보내지 않고 "
                                    + "검토 카드를 엽니다. Gemini 로 정리하지 못하면 앱이 정리한 문서로 넘깁니다.") {
                        Picker("취소할 시간", selection: $model.automaticHandoffDelay) {
                            Text("5초").tag(5)
                            Text("10초").tag(10)
                            Text("30초").tag(30)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } header: {
                Text("사용 한도에 닿으면")
            }

            Section {
                let targets = model.automaticHandoffTargetOrder
                ForEach(Array(targets.enumerated()), id: \.element.key) { index, target in
                    targetRow(target, index: index, count: targets.count)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("이어 받을 순서")
                    SettingsHelpButton(text: continueOrderNote, subject: "이어 받을 순서")
                }
            } footer: {
                SettingsFooter("한도에 걸린 쪽을 빼고, 위에서부터 여유가 확인된 첫 에이전트가 받습니다. 자동으로 넘길 때는 그때 한도를 다시 읽고, "
                               + "그래도 여유를 모르면 건너뜁니다. 입력창 위의 이어 가기 제안과 한도 안내의 이어 맡기기 단추도 이 순서를 따릅니다. "
                               + "체크를 끈 에이전트는 고르지 않습니다 (입력창의 에이전트 메뉴에서 직접 이어 맡기는 것은 됩니다).")
            }

            Section {
                SettingsChoiceRow(title: "앱이 정리",
                                  subtitle: "기록에서 확인한 사실(바꾼 파일, 실행한 명령, 남은 일)만 담습니다. 정리하는 데 외부 서비스를 쓰지 않습니다 — "
                                      + "정리된 문서는 넘길 때 받는 에이전트(그 회사의 CLI)에게 갑니다.",
                                  tag: "기본", selected: !model.geminiSummaryEnabled) {
                    model.geminiSummaryEnabled = false
                }
                SettingsChoiceRow(title: "Gemini 로 다듬기",
                                  subtitle: "더 읽기 좋게 요약합니다. 대화 · 명령 출력 · 변경 내용을 비밀값을 최선 노력으로 가린 뒤 Google 로 보내고, "
                                      + "요약은 기록과 맞춰 본 것만 넣습니다. Antigravity CLI(agy)로 부르므로 그 CLI 가 설치돼 있어야 합니다.",
                                  selected: model.geminiSummaryEnabled) {
                    model.geminiSummaryEnabled = true
                }
                if model.geminiSummaryEnabled {
                    if model.geminiCLIPath == nil {
                        SettingsWarning(text: "Antigravity CLI(agy)를 찾지 못해 Gemini 로 다듬을 수 없습니다 — 그동안 인계 문서는 앱이 정리합니다. "
                                            + "설정 > 에이전트 > Antigravity 에서 확인하세요.")
                    }
                    if model.automaticHandoffEnabled {
                        Text("자동으로 넘길 때는 Gemini 정리(수십 초)를 기다립니다. 정리하지 못하면 앱이 정리한 문서로 넘기고, "
                             + "정리본에 검증 경고가 있으면 넘기지 않고 카드를 열어 둡니다.")
                            .font(Theme.ui(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("요약 모델", selection: $model.geminiModel) {
                        if model.geminiModels.isEmpty {
                            Text("모델 목록 확인 필요").tag("")
                        } else {
                            ForEach(model.geminiModels.filter { $0.hasPrefix("gemini-") }, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    .disabled(model.geminiModels.isEmpty)
                    Text("보낸 내용은 Antigravity CLI 가 ~/.gemini/antigravity-cli 아래에 호출 기록으로 따로 남깁니다. 원본 기록과 프로젝트 파일은 "
                         + "고치지 않습니다. 프로젝트마다 끌 수 있습니다 — 사이드바의 프로젝트 메뉴 > 프로젝트 설정.")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("입력창의 에이전트 메뉴나 이어 가기 제안으로 연 카드는 앱이 정리한 문서로 먼저 열리고, 카드의 [Gemini 로 다시 정리]를 누를 때만 보냅니다.")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("인계 문서 정리")
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshGeminiStatus() }
    }

    /// 맨 위 한 줄 설명 — 보내는 쪽 → 문서 → 받는 쪽.
    private var explainer: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 6) {
                BrandMark(provider: .claude, size: 17)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.slate2)
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.slate)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.slate2)
                BrandMark(provider: .codex, size: 17)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("인계란?").fontWeight(.semibold)
                Text("한 에이전트의 사용 한도가 차거나 다른 에이전트에게 맡기고 싶을 때, 지금까지 한 일을 문서로 정리해 넘기는 것입니다. "
                     + "보내기 전에 문서를 보고 고칠 수 있습니다.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// 이어 받을 순서의 한 줄 — 받음 체크 · 순서 · 이름 · 상태(설치 · 로그인 · 한도) · 위 / 아래.
    private func targetRow(_ target: AppModel.AutomaticHandoffTarget, index: Int, count: Int) -> some View {
        let receives = !model.automaticHandoffExcluded.contains(target.key)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { receives }, set: { model.setAutomaticHandoffTarget(target.key, receives: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(receives ? "\(target.title): 이어 받음 — 끄면 자동 인계 · 이어 가기 제안 · 한도 줄이 고르지 않습니다"
                               : "\(target.title): 받지 않음 — 켜면 다시 고릅니다")
                .accessibilityLabel("\(target.title) 이어 받음")
            Text("\(index + 1)")
                .font(Theme.digits(.caption, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            BrandMark(provider: target.provider, size: 13)
            Text(target.title).lineLimit(1)
                .foregroundStyle(receives ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
            Spacer(minLength: 8)
            Text(receives ? targetStatus(target) : "받지 않음")
                .font(Theme.ui(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            IconButton(systemName: "chevron.up", size: 11, color: Theme.control, help: "\(target.title) 위로") {
                model.moveAutomaticHandoffTarget(target.key, by: -1)
            }
            .disabled(index == 0)
            IconButton(systemName: "chevron.down", size: 11, color: Theme.control, help: "\(target.title) 아래로") {
                model.moveAutomaticHandoffTarget(target.key, by: 1)
            }
            .disabled(index == count - 1)
        }
    }

    /// 대상의 상태 — 받을 수 없다고 확인됐으면 그 까닭(설치 안 됨 · 로그인 필요 — 칩 메뉴와 같은 판정), 아니면 한도.
    private func targetStatus(_ target: AppModel.AutomaticHandoffTarget) -> String {
        let agent = HandoffSource.Agent(provider: target.provider, codexAccountID: target.provider == .codex ? target.accountID : nil)
        let readiness = model.receiverReadiness(agent)
        if let block = ContinueChoice.handoffBlock(readiness, provider: target.provider) { return block.meta }
        let limit = limitSummary(model.limits.snapshot(target.scope))
        if let tag = ContinueChoice.readinessTag(readiness, provider: target.provider) { return "\(tag) · \(limit)" }
        return limit
    }

    /// 한도 요약 — 아직 읽지 않았으면 그 사실 ("정보 없음" 이라 하면 건너뛰는 것처럼 읽혔다 — 넘길 때 다시 읽는다).
    private func limitSummary(_ snapshot: LimitSnapshot) -> String {
        guard snapshot.fetchedAt != nil else { return "한도 아직 조회 안 함" }
        guard snapshot.status == .ok, snapshot.hasUsableData else {
            return snapshot.status == .noData ? "한도 정보 없음" : snapshot.status.koreanName
        }
        let peak = snapshot.windows.filter { $0.model == nil }.compactMap(\.utilization).max() ?? 0
        return peak >= 1 ? "한도 도달" : "최대 사용 \(Int((peak * 100).rounded()))%"
    }

    /// 이어 가기 제안 · 한도 줄도 이 순서를 쓴다는 자세한 안내 — 문턱은 판정의 상수에서.
    private var continueOrderNote: String {
        let short = Int(LimitSpan.short.threshold * 100), long = Int(LimitSpan.long.threshold * 100)
        return "입력창 위의 이어 가기 제안(5시간처럼 짧은 한도는 사용률 \(short)%, 주간처럼 긴 한도는 \(long)% 부터 · 받는 쪽은 계정 전체 최대 사용률이 \(short)% 미만이고 "
            + "보내는 쪽보다 낮은 대상)과 한도 도달 줄의 이어 맡기기 단추도 이 순서로 받는 쪽을 고릅니다 — 자동으로 넘기지 않게 해 두어도 쓰입니다. "
            + "Claude 한도는 한 번 실행하면 채워집니다."
    }
}
