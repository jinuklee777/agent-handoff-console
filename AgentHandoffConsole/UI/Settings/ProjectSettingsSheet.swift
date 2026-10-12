import SwiftUI

/// 프로젝트 하나의 설정 — 사이드바의 프로젝트 메뉴 > "프로젝트 설정…". 예전 설정 창이 프로젝트마다 펼치던 목록 넷을 모았다:
/// Antigravity 허용 · 인계 문서의 Gemini 전송 허용 · 독립 작업 폴더의 준비 명령 · (자동 작업을 켰으면) 검증 명령.
/// 저장 키는 예전 그대로다 (`antigravity_allowed_projects` · `gemini_excluded_projects` · `worktree_setup_commands` ·
/// `orchestration.settings` 의 `verificationCommands`). 명령은 사람이 여기 적은 것만 돈다.
struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var confirmingAntigravity = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    SettingsToggleRow(title: "Antigravity 쓰기",
                                      subtitle: "켜면 이 프로젝트에서 Antigravity 가 승인 없이 파일을 고치고 명령을 실행합니다.",
                                      isOn: Binding(get: { model.antigravityAllowed(projectID: project.id) }, set: { on in
                                          if on {
                                              confirmingAntigravity = true
                                          } else {
                                              confirmingAntigravity = false
                                              model.setAntigravityAllowed(false, projectID: project.id)
                                          }
                                      }))
                    if confirmingAntigravity && !model.antigravityAllowed(projectID: project.id) {
                        SettingsWarning(title: "이 프로젝트에서 Antigravity 를 쓸까요?",
                                        text: "Antigravity 는 승인을 묻지 않습니다. \(project.name) 안의 파일을 고치고 명령을 바로 실행합니다. "
                                            + "셸 명령은 설정 > 에이전트 > Antigravity 의 샌드박스를 따릅니다.") {
                            HStack(spacing: 8) {
                                Spacer()
                                Button("취소") { confirmingAntigravity = false }
                                Button("허용") {
                                    confirmingAntigravity = false
                                    model.setAntigravityAllowed(true, projectID: project.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.amberFill)
                            }
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Text("에이전트")
                }

                Section {
                    SettingsToggleRow(title: "인계 문서를 Gemini 로 보내도 됨",
                                      subtitle: model.geminiSummaryEnabled
                                          ? "끄면 이 프로젝트의 인계 문서는 앱이 정리합니다 (Google 로 보내지 않습니다)."
                                          : "설정 > 인계에서 ‘Gemini 로 다듬기’를 골랐을 때만 쓰입니다. 지금은 ‘앱이 정리’라 보내지 않습니다.",
                                      isOn: Binding(get: { !model.geminiExcludedProjectIDs.contains(project.id) },
                                                    set: { model.setGeminiAllowed($0, projectID: project.id) }))
                } header: {
                    Text("인계")
                }

                Section {
                    commandField(title: "새 독립 작업 폴더를 만든 뒤 실행할 명령",
                                 placeholder: "예: cp \"$AHC_PROJECT_DIR/.env\" . && npm install",
                                 text: Binding(get: { model.worktreeSetupCommands[project.id] ?? "" },
                                               set: { model.worktreeSetupCommands[project.id] = $0.isEmpty ? nil : $0 }),
                                 note: "새 독립 작업 폴더에는 커밋된 파일만 있습니다 (.env · node_modules 같은 무시된 파일은 없습니다). "
                                     + "여기 적은 명령만 로그인 셸로 실행하고, $AHC_PROJECT_DIR 는 이 프로젝트 폴더입니다.")
                } header: {
                    Text("독립 작업 폴더")
                }

                if model.orchestrationSettings.enabled {
                    Section {
                        commandField(title: "검증 명령",
                                     placeholder: "예: npm test",
                                     text: Binding(get: { model.orchestrationSettings.verificationCommands[project.id] ?? "" },
                                                   set: { value in
                                                       var next = model.orchestrationSettings
                                                       next.verificationCommands[project.id] = value.isEmpty ? nil : value
                                                       model.saveOrchestrationSettings(next)
                                                   }),
                                     note: "파일을 바꾸는 작업이 끝날 때와 마지막 통합 검증에서 이 폴더에서 실행하고, 실패하면 검토 없이 실패로 봅니다. "
                                         + "계획이나 에이전트가 제시한 명령은 돌리지 않습니다.")
                    } header: {
                        HStack(spacing: 6) {
                            Text("자동 작업")
                            SettingsTag(text: "실험")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: model.orchestrationSettings.enabled ? 820 : 660)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 17))
                .foregroundStyle(Theme.slate)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.well))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("프로젝트 설정 — \(project.name)").font(Theme.ui(.body, .semibold)).lineLimit(1)
                Text(SettingsActions.abbreviated(project.path))
                    .font(Theme.mono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// 명령 칸 — 셸 명령이라 스마트 따옴표 · 대시 · 자동 고침을 끈다 (`plainTextInput`).
    private func commandField(title: String, placeholder: String, text: Binding<String>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
            TextEditor(text: text)
                .font(Theme.mono(.caption))
                .plainTextInput()
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(height: 58)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(title)
            Text(note)
                .font(Theme.ui(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
