#!/bin/bash
# 앱의 실제(비 UI) 소스를 그대로 컴파일해 통합 검증 실행 파일을 만든다.
# AppModel 도 포함한다 (자동 인계 종단 검증). -D DEBUG 는 Debug 빌드 전용 시험 입구를 켠다.
# 가짜 어댑터로 일반 실행 경로를 대체하지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="build/inttest"
mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
# 이 Mac 의 아키텍처로 만든다 (Apple silicon 은 arm64, Intel 은 x86_64) — 다른 아키텍처로 만들면 이 Mac 에서 돌지 않는다.
ARCH="$(uname -m)"

xcrun swiftc \
  -sdk "$SDK" -target "$ARCH-apple-macos15.0" -swift-version 5 -Onone -g \
  -D DEBUG \
  -lsqlite3 \
  -o "$OUT/inttest" \
  AgentHandoffConsole/Core/Models.swift \
  AgentHandoffConsole/Core/ImageAttachment.swift \
  AgentHandoffConsole/Core/DisplayFormat.swift \
  AgentHandoffConsole/Core/CLINotices.swift \
  AgentHandoffConsole/Assist/GeminiAssist.swift \
  AgentHandoffConsole/Assist/AutomaticHandoffGate.swift \
  AgentHandoffConsole/Assist/ContinueSuggestion.swift \
  AgentHandoffConsole/Assist/ClaudeAPIContinue.swift \
  AgentHandoffConsole/Assist/CodexAccountSwitch.swift \
  AgentHandoffConsole/Assist/ContinueChoice.swift \
  AgentHandoffConsole/Assist/ThreadTitle.swift \
  AgentHandoffConsole/Storage/SQLiteDatabase.swift \
  AgentHandoffConsole/Storage/Migrations.swift \
  AgentHandoffConsole/Storage/Store.swift \
  AgentHandoffConsole/Storage/OrchestrationStore.swift \
  AgentHandoffConsole/Orchestration/OrchestrationPlan.swift \
  AgentHandoffConsole/Orchestration/OrchestrationState.swift \
  AgentHandoffConsole/Orchestration/OrchestrationScheduler.swift \
  AgentHandoffConsole/Orchestration/OrchestrationRouting.swift \
  AgentHandoffConsole/Orchestration/OrchestrationPrompts.swift \
  AgentHandoffConsole/Orchestration/OrchestrationCoordinator.swift \
  AgentHandoffConsole/Orchestration/VerificationCommandRunner.swift \
  AgentHandoffConsole/Orchestration/OrchestrationMetrics.swift \
  AgentHandoffConsole/Import/SessionImport.swift \
  AgentHandoffConsole/Agents/UnfairLock.swift \
  AgentHandoffConsole/Agents/LineFramer.swift \
  AgentHandoffConsole/Agents/ManagedProcess.swift \
  AgentHandoffConsole/Agents/CLIEnvironment.swift \
  AgentHandoffConsole/Agents/CodexAccountInspector.swift \
  AgentHandoffConsole/Agents/ClaudeAPIKey.swift \
  AgentHandoffConsole/Agents/AgentAdapter.swift \
  AgentHandoffConsole/Agents/ClaudeAdapter.swift \
  AgentHandoffConsole/Agents/CodexAdapter.swift \
  AgentHandoffConsole/Agents/CodexRunHome.swift \
  AgentHandoffConsole/Agents/CodexTurnTracker.swift \
  AgentHandoffConsole/Agents/ClaudeTurnTracker.swift \
  AgentHandoffConsole/Agents/AntigravityAdapter.swift \
  AgentHandoffConsole/Agents/ModelCatalog.swift \
  AgentHandoffConsole/Agents/EffortScale.swift \
  AgentHandoffConsole/Agents/ModelDefaults.swift \
  AgentHandoffConsole/Agents/SlashCommands.swift \
  AgentHandoffConsole/Pricing/PriceCatalog.swift \
  AgentHandoffConsole/Handoff/GitInspector.swift \
  AgentHandoffConsole/Handoff/HandoffPacketBuilder.swift \
  AgentHandoffConsole/Workspace/GitWorkspace.swift \
  AgentHandoffConsole/Workspace/GitWrite.swift \
  AgentHandoffConsole/Workspace/Worktrees.swift \
  AgentHandoffConsole/Workspace/GitFailure.swift \
  AgentHandoffConsole/Workspace/ChangesState.swift \
  AgentHandoffConsole/Workspace/FileDiff.swift \
  AgentHandoffConsole/Workspace/RunChanges.swift \
  AgentHandoffConsole/Workspace/BranchMenu.swift \
  AgentHandoffConsole/Workspace/GitHubCLI.swift \
  AgentHandoffConsole/Workspace/FileTree.swift \
  AgentHandoffConsole/Workspace/FilePreview.swift \
  AgentHandoffConsole/UI/Stream/StreamModel.swift \
  AgentHandoffConsole/UI/Stream/ThreadFind.swift \
  AgentHandoffConsole/UI/Stream/StreamFollow.swift \
  AgentHandoffConsole/UI/Stream/StreamReveal.swift \
  AgentHandoffConsole/UI/Stream/ApprovalPresentation.swift \
  AgentHandoffConsole/UI/Design/TypeScale.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/Core.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/Lattice.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/Morph.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/OrbSpec.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/Orbits.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/Presets.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/Strands.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/ThinkingOrb.swift \
  AgentHandoffConsole/UI/Design/ThinkingOrbs/Web.swift \
  AgentHandoffConsole/UI/Design/OrbLayer.swift \
  AgentHandoffConsole/UI/Stream/MarkdownText.swift \
  AgentHandoffConsole/UI/Stream/StreamSelection.swift \
  AgentHandoffConsole/Runtime/LimitsFetcher.swift \
  AgentHandoffConsole/Runtime/CodexAccountService.swift \
  AgentHandoffConsole/Runtime/RunSession.swift \
  AgentHandoffConsole/Runtime/RunCoordinator.swift \
  AgentHandoffConsole/Runtime/ReadOnlyRunPool.swift \
  AgentHandoffConsole/Runtime/LimitsService.swift \
  AgentHandoffConsole/Runtime/NotificationService.swift \
  AgentHandoffConsole/Workspace/WorkspaceModel.swift \
  AgentHandoffConsole/App/WindowState.swift \
  AgentHandoffConsole/App/SidebarRules.swift \
  AgentHandoffConsole/App/QuitConfirmation.swift \
  AgentHandoffConsole/App/PaneStatus.swift \
  AgentHandoffConsole/App/HandoffCard.swift \
  AgentHandoffConsole/App/ThreadPaneModel.swift \
  AgentHandoffConsole/App/AppModel.swift \
  AgentHandoffConsole/App/AppModel+Orchestration.swift \
  AgentHandoffConsole/App/AppModel+Composer.swift \
  AgentHandoffConsole/App/AppModel+Handoff.swift \
  AgentHandoffConsole/App/AppModel+Continue.swift \
  AgentHandoffConsole/App/AttentionBadge.swift \
  AgentHandoffConsole/App/AppModel+Worktree.swift \
  AgentHandoffConsole/App/FirstRunChecklist.swift \
  AgentHandoffConsole/App/ComposerRules.swift \
  AgentHandoffConsole/App/AppModel+Setup.swift \
  AgentHandoffConsole/App/AppModel+Title.swift \
  AgentHandoffConsole/App/AppModel+SlashCommands.swift \
  AgentHandoffConsole/App/AppModel+ClaudeAPI.swift \
  AgentHandoffConsole/App/AppModel+CodexSwitch.swift \
  AgentHandoffConsole/App/Overview.swift \
  AgentHandoffConsole/App/AppModel+Overview.swift \
  AgentHandoffConsole/UI/LimitsPresentation.swift \
  AgentHandoffConsole/UI/Settings/SettingsText.swift \
  scripts/inttest/TestKit.swift \
  scripts/inttest/OfflineTests.swift \
  scripts/inttest/ClaudeAPITests.swift \
  scripts/inttest/LiveTests.swift \
  scripts/inttest/CoordinatorTests.swift \
  scripts/inttest/MultiRunAppTests.swift \
  scripts/inttest/PaneStatusTests.swift \
  scripts/inttest/OverviewTests.swift \
  scripts/inttest/FirstRunTests.swift \
  scripts/inttest/StreamFoldTests.swift \
  scripts/inttest/TypeScaleLintTests.swift \
  scripts/inttest/HandoffSafetyTests.swift \
  scripts/inttest/HandoffCardTests.swift \
  scripts/inttest/LimitLineTests.swift \
  scripts/inttest/AntigravityLimitsTests.swift \
  scripts/inttest/ContinueTests.swift \
  scripts/inttest/MultiRunLiveTests.swift \
  scripts/inttest/BackgroundLiveTests.swift \
  scripts/inttest/AccountLiveTests.swift \
  scripts/inttest/WorkspaceTests.swift \
  scripts/inttest/BranchMenuTests.swift \
  scripts/inttest/RunChangesTests.swift \
  scripts/inttest/DiffTests.swift \
  scripts/inttest/GitWriteTests.swift \
  scripts/inttest/ComposerTests.swift \
  scripts/inttest/MarkdownTests.swift \
  scripts/inttest/ImportTests.swift \
  scripts/inttest/MigrationTests.swift \
  scripts/inttest/ScriptedAgentAdapter.swift \
  scripts/inttest/TurnOptionsTests.swift \
  scripts/inttest/TurnOptionsLiveTests.swift \
  scripts/inttest/SubAgentRunTests.swift \
  scripts/inttest/SubAgentUITests.swift \
  scripts/inttest/ComposerFlowTests.swift \
  scripts/inttest/ThreadTitleTests.swift \
  scripts/inttest/SlashCommandTests.swift \
  scripts/inttest/OrbTests.swift \
  scripts/inttest/WorktreeTests.swift \
  scripts/inttest/ProcessTreeTests.swift \
  scripts/inttest/StaleResumeLiveTests.swift \
  scripts/inttest/ReleaseFixLiveTests.swift \
  scripts/inttest/OrchestrationTests.swift \
  scripts/inttest/OrchestrationCoordinatorTests.swift \
  scripts/inttest/GeminiAssistTests.swift \
  scripts/inttest/AutoHandoffLiveTests.swift \
  scripts/inttest/AntigravityLiveTests.swift \
  scripts/inttest/GeminiCompare.swift \
  scripts/inttest/ProbeLogs.swift \
  scripts/inttest/CodexReplayTests.swift \
  scripts/inttest/ClaudeReplayTests.swift \
  scripts/inttest/AntigravityStreamTests.swift \
  scripts/inttest/CodexSwitchTests.swift \
  scripts/inttest/main.swift

echo "빌드 완료: $OUT/inttest"
