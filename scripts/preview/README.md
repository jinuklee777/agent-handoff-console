# 화면 확인 도구

앱을 사용자 설정 · DB 와 섞지 않고 띄워 창을 찍는다 — 상태별 화면 확인 · 성능 측정 · README 이미지가 이 길을 쓴다. 결과는 모두 `$TMPDIR/ahc-preview/` (바꾸려면 `PREVIEW_DIR`) 에 쌓인다. 임시 폴더라야 git 명령을 실제로 실행하거나 실행을 합성하는 미리보기 인수(`push` · `runSummary` 등)가 동작한다.
실제 CLI 를 부르지 않는다 (`AHC_OFFLINE=1`). Debug 빌드 전용 미리보기 인수는 아래 "미리보기 인수" 표에 있다.

```bash
# 1. 상태별 시나리오 저장소 → $TMPDIR/ahc-preview/repos/<이름>/… (인수 없이 부르면 기본 시나리오 전부)
bash scripts/preview/scenarios.sh
bash scripts/preview/scenarios.sh pushreject authfail pulloverlap incomingfiles   # 실패 표시용
bash scripts/preview/scenarios.sh s3branches s3push                               # 브랜치 메뉴 · 진행 중 (main · committed 먼저)

# 2. 미리보기 번들 ID 로 앱 빌드 (사용자 앱과 환경설정이 섞이지 않는다) + seed 용 검증 실행 파일
xcodebuild -project AgentHandoffConsole.xcodeproj -scheme AgentHandoffConsole -configuration Debug \
  -derivedDataPath build/DerivedData-preview PRODUCT_BUNDLE_IDENTIFIER=io.github.jinuklee777.AgentHandoffConsole.preview build
./scripts/build-inttest.sh

# 3. 캡처 → $TMPDIR/ahc-preview/shots/<결과이름>.png (1440x900 창, 2배율)
bash scripts/preview/capture.sh main main-now
bash scripts/preview/capture.sh s3branches menu-sso -preview.action branchMenu:sso
bash scripts/preview/capture.sh main run-card -preview.action runSummary
bash scripts/preview/capture.sh main diff-login -preview.action review:Moa/Login/LoginView.swift -diff.wideMode split
# 입력창 모델 칩 팝오버 — 모델 목록 캐시 · 스레드 선택을 임시 DB 에 넣고(SEED_ARGS) 팝오버를 연 채 (창 캡처에 팝오버도 함께 찍힌다)
SEED_ARGS="--models --selection=claude:opus:high" bash scripts/preview/capture.sh main composer-high -preview.action modelPicker
SEED_ARGS="--models --selection=gemini:gemini-3.8-flash:boost" bash scripts/preview/capture.sh main composer-boost -preview.action modelPicker
# 입력창 에이전트 칩 팝오버 (에이전트 · Codex 계정) — 기록이 없는 대화면 행이 칩만 바꾼다
SEED_ARGS="--models --selection=codex:gpt-5.6-sol:high --codex-accounts" bash scripts/preview/capture.sh main provider-menu -preview.action providerMenu
# 칩 = 이어 가기 (C3): Claude 가 일한 기록(--history)이 있는 대화 — "… 에게 이어 맡기기" 행과 펼친 "맥락 없이 바꾸기". 계정 행의 사용률은 -preview.limits
SEED_ARGS="--models --history --codex-accounts" INSPECTOR=NO bash scripts/preview/capture.sh main chip-menu -preview.action providerMenu \
  -preview.limits "claude=0.81@5h+0.42@7d;codex=0.12@5h;codex:codex-preview-2=0.40@5h"
# Codex 계정 바꾸기: Codex(기본 계정)가 일한 대화(--codex-history)의 칩 메뉴 — 다른 계정 행 = "같은 세션을 이 계정으로 이어 갑니다" (인계 아님)
SEED_ARGS="--models --codex-history --codex-accounts" INSPECTOR=NO bash scripts/preview/capture.sh main chip-menu-codex -preview.action providerMenu
# 자동 인계가 다른 Codex 계정을 골랐을 때의 카운트다운 줄 (입력창 위 — 타이머 없이 60초)
WAIT=6 SEED_ARGS="--models --codex-history --codex-accounts" INSPECTOR=NO bash scripts/preview/capture.sh main codex-switch -preview.codexSwitch YES
# 같은 카운트다운이 자동 인계 카운트다운처럼 보이는 곳 — 칸 머리 "다른 계정에서 이어 가기 대기" · 사이드바 "계정 n초" (두 칸), 현황의 행
# (비교: 자동 인계 카운트다운은 `--handoff` 와 -preview.action handoffCountdown)
WAIT=6 SEED_ARGS="--models --codex-history --codex-accounts --threads=4 --panes=2" INSPECTOR=NO bash scripts/preview/capture.sh main codex-switch-panes -preview.codexSwitch YES
WAIT=6 SEED_ARGS="--models --codex-history --codex-accounts" INSPECTOR=NO bash scripts/preview/capture.sh main codex-switch-overview -preview.codexSwitch YES -window.pane overview
# 카드가 있을 때의 칩 메뉴 (받는 쪽 = 카드로 · 보내는 쪽 = 거두기 · 다른 쪽 = 받는 쪽 바꾸기) — -preview.card 가 카드를 함께 놓는다
WAIT=7 SEED_ARGS="--models --history --codex-accounts" INSPECTOR=NO bash scripts/preview/capture.sh main chip-menu-card -preview.action providerMenu -preview.card handoff:codex
# 한도 임박 이어 가기 제안 줄 (C4) — 한도 · CLI · 로그인 사실을 -preview.limits 로 (형식은 아래 "미리보기 인수" 표). 한도 새로 읽기도 그 값이다
WAIT=6 SEED_ARGS="--models --history" INSPECTOR=NO bash scripts/preview/capture.sh main suggest -preview.limits "claude=0.81@5h+0.42@7d;codex=0.12@5h+0.30@7d"
WAIT=6 SEED_ARGS="--models --history" INSPECTOR=NO bash scripts/preview/capture.sh main suggest-dark -preview.limits "claude=0.81@5h+0.42@7d;codex=0.12@5h+0.30@7d" -preview.appearance dark
WAIT=8 SEED_ARGS="--models --history --threads=4 --panes=4" bash scripts/preview/capture.sh main suggest-grid -preview.limits "claude=0.81@5h;codex=0.12@5h"   # 좁은 칸 — "사용률 81%" · 단추 하나 · ×

# API 크레딧으로 계속 — 키가 저장된 것처럼(-preview.claudeAPIKey, 메모리에만). 한도 도달 줄(--handoff 의 한도로 멈춘 실행) · 한도 인계 카드 · 제안 줄
WAIT=6 SEED_ARGS="--models --handoff" INSPECTOR=NO bash scripts/preview/capture.sh main apicontinue-limit -preview.claudeAPIKey YES -preview.limits "claude=1.0@5h,status=cap;codex=0.12@5h"
WAIT=7 SEED_ARGS="--models --handoff" INSPECTOR=NO bash scripts/preview/capture.sh main apicontinue-card -preview.claudeAPIKey YES -preview.action handoffCountdown
WAIT=6 SEED_ARGS="--models --history" INSPECTOR=NO bash scripts/preview/capture.sh main apicontinue-suggest -preview.claudeAPIKey YES -preview.limits "claude=0.81@5h;codex=0.12@5h"
WAIT=6 SEED_ARGS="--models --handoff" INSPECTOR=NO bash scripts/preview/capture.sh main apicontinue-nokey -preview.limits "claude=1.0@5h,status=cap;codex=0.12@5h"   # 키 없음 — 설정으로 가는 안내
# 입력창 조작 줄의 밀도 — Codex 계정 2개(--codex-accounts) 로 계정 칩까지 켜고, 사이드바가 접히는 좁은 창(인스펙터 열림 · 본문 = 창 − 400)에서
SEED_ARGS="--models --selection=codex:gpt-5.6-sol:high --codex-accounts" SIZE="1440x900,900x760" bash scripts/preview/capture.sh main composer-narrow

# 자동 작업 카드 — 첫 스레드에 자동 작업을 그 상태로 넣는다 (running · approval · blocked · clarify). 자동 작업 설정도 켜진다
SEED_ARGS="--models --orchestration=running" bash scripts/preview/capture.sh main orch-running
SEED_ARGS="--models --orchestration=blocked" bash scripts/preview/capture.sh main orch-blocked

# 분할 화면 — 스레드를 채우고(`--threads=`) 앞에서부터 칸에 연다. 마지막 칸은 빈 칸으로 남는다 (2 또는 4)
SEED_ARGS="--models --threads=4 --panes=2" bash scripts/preview/capture.sh main panes-2
SEED_ARGS="--models --threads=4 --panes=4" bash scripts/preview/capture.sh main panes-4 -preview.typeKeys "a b ret"   # 여러 입력창에서도 ↵ 보내기

# 하위 에이전트 — 끝난 실행 하나(하위 에이전트 둘 · 끝을 보고받지 못한 백그라운드 명령 하나)를 넣고 인스펙터 "에이전트" 탭으로
SEED_ARGS="--models --subagents=done" TAB=agents bash scripts/preview/capture.sh main subagents
# 하위 여섯(다섯은 앞에서 sleep 10 — 목록에 셸이 따로 나오지 않아야 한다 · 여섯째는 뒤에서 도는 셸을 띄움) — 긴 목록 · 들임 · 실행 머리
SEED_ARGS="--models --subagents=done,fanout" TAB=agents bash scripts/preview/capture.sh main subagents-list
# 기다리는 중(메인 턴을 마치고 남은 하위를 기다림) — 앱 안의 DEBUG 가짜 어댑터(`PreviewSubAgentAdapter`)로 실행을 시작한다
WAIT=6 SEED_ARGS="--models" TAB=agents bash scripts/preview/capture.sh main subagents-waiting -preview.action subagents
# 분할 화면의 칸 머리 · 툴바 "응답 필요" — 칸마다 가짜 실행(완료 · 승인 대기 · 실행 중)과 칸에 없는 대화의 질문. 보내기가 차례로 시작해 오래 기다린다
WAIT=14 SEED_ARGS="--models --threads=4 --panes=4" bash scripts/preview/capture.sh main panes-status -preview.action panes
WAIT=14 SIZE=1180x800 SEED_ARGS="--models --threads=4 --panes=4" bash scripts/preview/capture.sh main panes-narrow -preview.action panes   # 좁은 칸의 짧은 문구
# 입력창 곁 부품 — 첫 칸은 편집 승인 카드(diff), 둘째 칸은 실행 중 상태 줄 · 걸어 둔 메시지 둘 · 붙인 이미지 · 쓰는 중인 글 (`[편집]` · `[실행]` 가짜 실행)
WAIT=9 SEED_ARGS="--models --threads=4 --panes=4" bash scripts/preview/capture.sh main composer -preview.action composer
# 실행 중 상태 줄의 점 구(`RunOrb`) — 칸마다 생각 · 명령 · 찾기 · 답변 쓰기에 머무는 가짜 실행 (모양 확인 · CPU 재기)
WAIT=10 SEED_ARGS="--models --threads=4 --panes=4" INSPECTOR=NO bash scripts/preview/capture.sh main run-status -preview.action runStatus
# 응답이 흐르는 동안의 맨 아래 따라가기 — 긴 답을 30ms 마다 흘리고 0.1초마다 맨 아래까지 남은 거리를 $TMPDIR/ahc-preview/stream.log 에 적는다.
# -preview.wheel "4:up,8:down" 이면 4초에 휠 한 칸 올림(따라가기를 멈추고 그 자리에 머물러야 한다) · 8초에 맨 아래까지 내림(다시 따라가야 한다)
SIZE=1200x700 WAIT=17 INSPECTOR=NO SEED_ARGS="--models --history" bash scripts/preview/capture.sh main stream -preview.action stream -preview.wheel "4:up,8:down"
# 같은 흐름을 조각이 크게 띄엄띄엄 오게 — 받은 조각을 고른 속도로 풀고(`StreamReveal`) 새 글자가 서서히 나타나는지 (KEEP=1 로 띄워 두고 본다)
KEEP=1 SIZE=1200x700 WAIT=6 INSPECTOR=NO SEED_ARGS="--models --history" bash scripts/preview/capture.sh main stream-burst -preview.action stream -preview.streamPattern burst

# 인계 카드 — 첫 스레드에 Claude 가 일한 기록(끝난 실행 · 한도로 멈춘 실행)을 넣고(--handoff) 대화 끝에 카드를 놓는다 (게이트 · 타이머 · 전송은 하지 않는다)
# 종류: handoff(수동 · 확인 체크됨) · handoffCountdown(자동 인계 카운트다운 30초) · handoffReview(게이트가 막은 검토) · handoffFailed · handoffUnknown
# 받는 쪽은 `handoff:codex` 처럼, 걸어 둔 메시지는 -preview.handoffQueue YES (입력창의 받는 쪽 표시 · 보류된 대기열), 덧붙일 말은 -preview.handoffMemo "<글>"
WAIT=7 SEED_ARGS="--models --handoff" bash scripts/preview/capture.sh main handoff -preview.action handoff -preview.handoffQueue YES
WAIT=7 SEED_ARGS="--models --handoff" bash scripts/preview/capture.sh main handoff-countdown -preview.action handoffCountdown
WAIT=8 SEED_ARGS="--models --handoff --threads=4 --panes=4" bash scripts/preview/capture.sh main handoff-grid -preview.action handoffCountdown   # 좁은 칸 — 접힌 카드
WAIT=7 SEED_ARGS="--models --handoff" bash scripts/preview/capture.sh main handoff-dark -preview.action handoffReview -preview.appearance dark

# 대화별 독립 작업 폴더 — 선택된 대화에 worktree 를 만들고(임시 DB 옆 worktrees) 파일 하나를 바꿔 변경사항 탭 위의 작업 폴더 칸을 · 시작 화면의 폴더 고르기
WAIT=7 SEED_ARGS="--models" bash scripts/preview/capture.sh main worktree -preview.action worktree
WAIT=6 SEED_ARGS="--models" bash scripts/preview/capture.sh main worktree-fresh -preview.action worktreeFresh

# 첫 실행 점검표 — 프로젝트를 seed 하지 않는다(SEED=none, 시나리오 이름은 아무것이나). 사실은 -preview.firstRun 으로 준다
#   claude=ready|unknown|nologin|missing|badpath|checking · codex=… · agy=… · notify=allowed|denied|ask|unknown|checking · badge=on|off · git=yes|no|unknown
#   (적지 않은 것은 준비된 값, Antigravity 는 기본 설치 안 됨 — `FirstRunFacts.preview`). 실제 CLI · 알림 권한은 묻지 않는다
SEED=none INSPECTOR=NO bash scripts/preview/capture.sh none firstrun-ready -preview.firstRun "" -ApplePersistenceIgnoreState YES
SEED=none INSPECTOR=NO bash scripts/preview/capture.sh none firstrun-missing -preview.firstRun "claude=nologin,codex=missing,notify=ask" -ApplePersistenceIgnoreState YES
SEED=none INSPECTOR=NO bash scripts/preview/capture.sh none firstrun-dark -preview.firstRun "claude=unknown,codex=unknown,notify=denied,git=no,agy=unknown" -preview.appearance dark -ApplePersistenceIgnoreState YES
# 도움말 > 시작 점검… 의 시트 (프로젝트가 있을 때)
WAIT=5 SEED_ARGS="--models" bash scripts/preview/capture.sh main firstrun-sheet -preview.action firstRunSheet -preview.firstRun "badge=off,codex=nologin"
```

- `capture.sh` 는 앞서 띄운 미리보기 앱을 끄고, 시나리오마다 새 임시 DB 에 프로젝트를 seed 한 뒤 `open -g` 로 뒤에서 띄워 그 창만 `screencapture -l` 로 찍는다.
  환경변수: `TAB`(인스펙터 탭 — terminal · files · pullRequest · changes · agents, 기본 changes) · `WAIT`(초, 기본 4) · `SIZE`(기본 1440x900) · `KEEP=1`(찍고 끄지 않음).
  인스펙터는 기본으로 편 채로 띄운다 (`-inspector.visible YES` — 미리보기 번들의 환경설정에 숨김이 남아 있어도, `INSPECTOR=NO` 면 접는다).
  `SEED=none` 은 seed 하지 않은 빈 DB 로 띄운다 (첫 실행 점검표 — 시나리오 저장소가 없어도 된다).
- 팝오버는 `KEEP=1` 로 띄운 뒤 `$TMPDIR/ahc-preview/tools/popwin <pid>` 가 준 창 번호를 `screencapture -o -x -l <번호>` 로 찍는다.
- 뒤에서 뜬 창은 키 포커스를 받지 않는다 — 키 입력 · 포커스 링은 이 도구로 확인할 수 없다.
- 시나리오 저장소에서 앱으로 git 쓰기를 해 봤다면 `scenarios.sh <이름>` 으로 다시 만든다. 화면 기록(macOS 화면 기록 권한)이 필요하다.

## 미리보기 인수 (Debug 빌드 전용)

실제 기록과 CLI 를 건드리지 않고 화면만 확인할 때 쓴다. Release 빌드에는 들어가지 않는다. 위 `capture.sh` 는 이 인수를 앱에 그대로 넘긴다.

| 항목 | 효과 |
|---|---|
| `AHC_DATABASE_PATH=<경로>` | 기본 DB 대신 이 파일을 쓴다 |
| `AHC_OFFLINE=1` | 시작 시 CLI 확인·한도·모델 목록 조회와 알림 권한 요청을 하지 않는다 (git 읽기는 한다). 변경사항 탭을 열 때의 gh PR 조회도 하지 않는다 |
| `-preview.appearance dark` | 다크 모드로 띄운다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action handoff` · `handoffCountdown` · `handoffReview` · `handoffFailed` · `handoffUnknown` (`:<claude\|codex\|gemini>`) | 시작 직후 선택된 대화의 끝에 인계 카드를 놓는다 — 수동(확인 체크됨) · 자동 인계 카운트다운(30초, 타이머 없음) · 게이트가 막은 검토 · 보내지 못함 · 전달 미확인. 게이트 · 타이머 · 전송은 하지 않는다. 대화에 실행 기록이 있어야 한다 (seed 의 `--handoff`). 받는 쪽을 지정할 수 있다 — `gemini` 는 받는 모델 칩을 보려고 `AHC_DATABASE_PATH` 로 연 DB · 임시 폴더 안의 프로젝트에서만 그 프로젝트의 Antigravity 를 켠다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action toolRun` | 도는 실행의 실행 기록: 선택된 대화에 가짜 어댑터(`PreviewPaneAdapter` 의 `[도구들]`)로 읽기 · 찾기 · 설명이 붙은 명령(하나는 실패)을 1초 간격으로 하나씩 돌리고 마지막 명령에 머문다 — 블록이 접힌 채 수만 바뀌는지 · 지금 하는 일이 상태 줄 한 줄인지. CLI 를 부르지 않는다. `AHC_DATABASE_PATH` 로 연 DB · 임시 폴더 안의 프로젝트에서만 (`AHC_OFFLINE=1` 일 때만) |
| `SEED_ARGS="--execlog"` · `-preview.execFold expanded\|steps\|issues` | 실행 기록 접기 (`ExecutionFold`): seed 의 `--execlog` 는 첫 대화에 Claude 실행 하나(설명이 붙은 명령 · 실패한 테스트 · 다시 돌려 통과)와 Codex 실행 하나(추론 요약의 머리 · 실패 · 멈춘 명령)를 넣는다. `-preview.execFold` 는 블록의 처음 상태 — `expanded` 단계 줄까지 · `steps` 단계마다 자세히까지 · `issues` 오류 등의 단계만 자세히 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.handoffQueue YES` · `-preview.handoffMemo <글>` | 위 인계 카드와 함께: 걸어 둔 메시지 하나(입력창의 받는 쪽 표시 · 보류된 대기열) · 덧붙일 말 칸의 글 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.cardFrameFile <경로>` | 인계 카드의 창 안 자리(포인트)와 창 크기를 JSON 으로 적는다 — README 이미지가 카드만 자른다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.notificationThread <대화 ID>` | 창이 없을 때 알림을 눌러 열린 상황을 만든다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action changesSearch` | 시작 직후 ⌘⇧F 를 누른 상황 (변경사항 탭 찾기 칸) (`AHC_OFFLINE=1` 일 때만) |
| `-preview.commitDraft <메시지>` | 변경사항 탭의 커밋 메시지 초안을 채운다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action push` · `pull` · `fetch` | 시작 직후 그 git 명령을 **실제로** 실행한다 (확인을 거친 것으로 본다). 실패 표시(업로드 거절 · 로그인 필요 · 겹치는 변경)를 시나리오 저장소의 실제 출력으로 확인할 때 쓴다. 지어낸 결과를 넣지 않는다. 확인 창을 건너뛰므로 임시 폴더(`/tmp` · `/private/var/folders`) 안의 프로젝트에서만 실행한다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action mergeHowTo` · `abortHelp` · `pullConfirm` · `pushConfirm` | 변경사항 탭의 그 팝오버(합치는 방법 · 합치기를 멈추는 방법 · 받기 확인 · 업로드 확인)를 연 채 시작한다. 버튼이 보이는 상태에서만 열린다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action branchMenu` · `branchMenu:<글자>` · `newBranch` | 브랜치 메뉴를 연 채 (그 글자를 친 찾기 상태로 · 새 이름 입력 상태로) 시작한다. `newBranch` 는 ⌘⇧N 과 같은 길(모델에 남긴 요청을 탭이 받음)로 연다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action targetChange:<브랜치>` | 업로드 확인 창을 연 채 그 브랜치로 **실제로** 전환해 "브랜치가 바뀌었습니다" 안내를 본다. git 쓰기라 `push` 와 같이 임시 폴더 안의 프로젝트에서만 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.pullRequest <JSON 경로>` | `gh pr view --json …` 형식의 파일을 앱의 해석기(`GitHubCLI.parseView`)로 읽어 지금 브랜치의 PR 캐시에 넣는다 — 변경사항 탭 PR 행 · 업로드 성공의 "PR #n에 반영" 을 gh 없이 확인할 때. 값을 코드에서 만들지 않는다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action runSummary` | 실행 전후 비교 카드 · 변경사항 탭 점을 본다. 실행이 없는 미리보기라 끝난 실행 하나를 **이 DB 에만** 합성하고, 요약은 앱의 실제 스냅샷 · 차이 함수로 만든다 (실행 전 = 빈 스냅샷 — 지금 바뀐 파일이 모두 실행 전에 깨끗했다고 본다, 실행 후 = 지금 폴더를 실제로 읽은 값). 저장소가 아닌 폴더면 비교할 수 없어 "관찰된 편집 n건" 카드가 되고, 그때의 편집 기록은 폴더의 파일 이름으로 만든 합성 기록이다 (대화에 "화면 확인용" 이라고 적는다). `AHC_DATABASE_PATH` 로 연 DB · 임시 폴더 안의 프로젝트에서만 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action runSummaryReview` | `runSummary` 뒤 카드의 "변경사항 검토" 칩과 같은 길(변경사항 탭으로 열기 + 그 실행의 파일을 위로 올리는 요청)을 탄다. `-inspector.tab` 을 함께 주면 실행 인자가 창 상태를 덮어써 탭은 바뀌지 않으므로, 올린 목록은 `-inspector.tab changes` 와 함께 본다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action diff:<경로>` · `review:<경로>` | 그 파일(저장소 루트 기준)의 diff 를 좁은 패널 · 크게 보기로 연 채 시작한다 (행을 누른 것과 같은 길). 크게 보기의 통합 · 나란히는 `-diff.wideMode unified` · `split` 로 덮어쓴다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.scrollProbe <초>` | diff 성능 측정: 위의 `diff:` · `review:` 로 연 순간부터 메인 스레드 응답을 16ms 마다 재고(150ms 넘으면 끊김, 3초 넘으면 멈춤), 첫 행이 보인 2초 뒤부터 그 초 동안 앱 안에서 diff 의 스크롤 뷰에 휠 이벤트를 직접 보내 왕복한 뒤 `-preview.scrollProbeJump <초>`(기본 10) 동안 무작위 위치로 뛴다. 속도는 `-preview.scrollSpeed <pt>`(기본 160pt/이벤트 · 60Hz). 결과는 `-preview.probeOut <경로>` 에 JSON 한 줄. 전역 이벤트를 만들지 않는다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.sidebarHidden YES` | 사이드바를 접은 채 시작한다 (툴바의 사이드바 버튼 · 제목 자리 확인) (`AHC_OFFLINE=1` 일 때만) |
| `-preview.sweepDivider inspector\|sidebar[:거리][:stay]` | 구분선을 끈다 — 인스펙터는 창의 NSSplitView 구분선에 합성 마우스 이벤트를 넣고, 사이드바는 앱이 그린 1pt 선이라 합성 이벤트를 받지 않아 저장된 너비(`sidebar.width`)를 같은 박자로 1pt 씩 바꾼다 (macOS 26 구분선 드래그 크래시 재현용). 음수 거리는 반대 방향, `:stay` 는 끝점에서 되돌리지 않음, `;` 로 이어 차례로 끈다 (`inspector:150:stay;sidebar:200`). 진행과 칸 제약 상수는 `$TMPDIR/ahc-preview/sweep.log` 에 남는다. `-preview.sweepMutate <초>` 는 그 시점부터 가운데 칸을 대화 ↔ 에이전트 기록으로 바꾼다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.slash YES` | 입력창 "/" 목록을 CLI 대신 견본(Claude 명령 · 스킬, Codex 스킬)으로 채운다. `-preview.typeKeys "insert:/co down"` 과 함께 목록 · 고른 줄을 찍는다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.typeKeys "a b ret"` | 입력창 텍스트 뷰를 첫 응답자로 만들고 키를 넣어 ↵ 보내기 · ⇧↵ 줄바꿈을 확인한다 (토큰: 한 글자 · 한글 자모 · `sp` · `ret` · `sret` · `oret` · `up` · `down` · `tab` · `esc` · `mark:<글>` — 입력기가 조합 중인 글을 넣는 호출(`setMarkedText`)을 직접 해서 입력 소스와 무관하게 한글 조합 상태를 만든다). 결과는 `sweep.log` 의 `typeKeys` · `SEND` 줄 — 오프라인에서는 CLI 를 부르지 않고 보냈다는 기록만 남긴다. `-preview.activate YES` 를 더하면 창을 앞으로 가져와 실제 이벤트 큐로 넣는다 (`NSApp.currentEvent` 가 그 키가 되어 수식키 판정이 실제와 같다). 한글 IME 조합은 합성 이벤트로는 일어나지 않아 사람이 확인한다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action modelPicker` | 입력창 모델 칩의 팝오버(강도 목록 · 모델 목록 — 모델 쪽은 `-preview.pickerPage models` 를 더한다)를 연 채 시작한다. 오프라인 미리보기는 모델 목록을 조회하지 않으므로 목록 · 대화의 선택은 `inttest seed <폴더> --models --selection=<claude\|codex\|gemini>:<모델>:<강도>` 로 임시 DB 에 넣는다 (`--codex-accounts` 를 더하면 두 번째 Codex 계정 "계정2" 도 등록해 입력창의 계정 칩이 보인다 · `--threads=6` 은 대화를 6개로 채워 사이드바의 3개 제한 · "더보기" · 접기를 볼 수 있다) (`scripts/preview/capture.sh` 의 `SEED_ARGS` — `AHC_DATABASE_PATH` 로 연 DB 에만 쓰고, 없으면 건너뛴다) — 목록은 CLI 형식의 고정 응답을 앱의 해석기로 읽은 값 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action providerMenu` | 입력창 에이전트 칩의 팝오버(에이전트 · Codex 계정 행, 기록이 있으면 "… 에게 이어 맡기기" 행과 펼친 "맥락 없이 바꾸기")를 연 채 시작한다. 계정 행은 `--codex-accounts`, 기록(Claude 가 일한 끝난 실행 둘)은 `--history` 로 seed 한다. 카드가 있을 때의 메뉴는 `-preview.card handoff:codex` 를 더한다 (`-preview.action handoff…` 와 같은 값 — 다른 `-preview.action` 과 함께 카드를 놓는다) (`AHC_OFFLINE=1` 일 때만) |
| `-preview.limits <사실>` | 한도 · CLI · 로그인 사실을 넣는다 — 이어 가기 제안 줄 · 한도 도달 줄의 대상 확인용. 한도 새로 읽기도 넣은 값을 돌려준다 (실제 `claude -p /usage` · Codex 를 부르지 않는다). 항목은 `;` 로 나눈다: `<claude\|codex\|codex:<계정 ID>>=<사용률>[@<5h\|7d\|<n>m\|<n>h\|<n>d>][+<창>…][,fetched=now\|-<n>m][,resets=+<n>h\|none][,status=ok\|cap][,login=yes\|no\|unknown][,cli=yes\|no]` (예: `"claude=0.81@5h+0.42@7d;codex=0.12@5h"`). 길이를 쓰지 않은 창은 5시간, 초기화는 짧은 창 +2시간 · 긴 창 +3일, 로그인 · CLI 는 적지 않으면 됨. 마지막 메인 이벤트가 한도 안내면 제안이 숨으므로 seed 는 `--history`(한도 안내 없음)로 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.agyUsage <파일>` | `agy -p /usage --output-format json` 응답을 담은 파일을 앱의 해석기로 읽어 Antigravity 한도로 넣는다 — 허용한 프로젝트가 있는 것처럼 (한도 칩 · 팝오버 · 메뉴바 · 현황 · 인계 카드의 받는 쪽 줄 확인용). 한도 새로 읽기도 그 값이다 — 실제 agy 를 부르지 않는다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.claudeAPIKey YES` | Claude API 키가 저장된 것처럼 한다 (메모리에만 — 키체인을 건드리지 않는다). 한도 도달 줄 · 한도 인계 카드 · 이어 가기 제안 줄의 "API 크레딧으로 계속" 확인용 — 한도 줄은 seed `--handoff`, 제안 줄은 `--history` + `-preview.limits` 와 함께 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.firstRun <사실>` | 첫 실행 점검표가 보는 사실을 넣는다 — 실제 CLI · 로그인 · 알림 권한 · `xcode-select` 를 묻지 않는다. 쉼표로 이은 `이름=값`: `claude=` · `codex=` · `agy=` 는 `ready` · `unknown`(로그인 모름) · `nologin` · `missing` · `badpath`(설정의 경로 오류) · `checking`, `notify=allowed\|denied\|ask\|unknown\|checking`, `badge=on\|off`, `git=yes\|no\|unknown`. 적지 않은 것은 준비된 값 (Claude · Codex 로그인됨, 알림 허용 · 배지 켬, Git 있음, Antigravity 설치 안 됨). 점검표 자체는 프로젝트가 없는 DB 에서 보인다 (`capture.sh` 의 `SEED=none`) (`AHC_OFFLINE=1` 일 때만) |
| `-preview.settings <탭>` · `-preview.settingsHeight <높이>` | 설정 창을 그 탭(`general` · `agents` · `handoff` · `automation` · `advanced` · `about`)으로 연다. 긴 탭은 높이를 키워 한 장에 (기본 640). 설정 창은 주 창이 아니라 `KEEP=1` 로 띄운 뒤 `popwin` 이 준 창 번호로 찍는다. 에이전트 카드의 상태는 `-preview.firstRun` 의 사실을 따른다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.fileSelect <경로>` | 파일 탭에서 그 파일(프로젝트 폴더 기준 경로)을 고른 채로 연다 — 미리보기 확인용 (`TAB=files` 와 함께, `AHC_OFFLINE=1` 일 때만) |
| `-preview.projectSettings YES` | 선택된 대화의 프로젝트 설정 시트(사이드바의 프로젝트 메뉴 > "프로젝트 설정…")를 연 채 시작한다. 시트도 `popwin` 으로 찍는다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action firstRunSheet` | 도움말 > 시작 점검… 의 시트를 연 채 시작한다 (프로젝트가 있는 사람의 점검표 — 사실은 `-preview.firstRun`) (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action import` | 기록 가져오기 시트를 연 채 시작한다. 이 Mac 의 실제 `~/.claude` · `~/.codex` 를 읽기만 한다 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action subagents` | 하위 에이전트를 기다리는 실행을 본다: 앱 안의 가짜 어댑터(`UI/PreviewSubAgentAdapter.swift`)로 선택된 대화에 실행을 시작해 (실제 실행기를 거친다), 하위 둘을 띄우고 하나를 남긴 채 메인 턴을 마친 상태(머리줄 "백그라운드 작업 1개 기다리는 중" · 대화의 카드 · 에이전트 탭 · 입력창 안내)에 머문다. ⌘. 로 멈추면 취소, 에이전트 탭에서 남은 하위를 멈추면 완료로 끝난다. CLI 를 부르지 않는다. `AHC_DATABASE_PATH` 로 연 DB · 임시 폴더 안의 프로젝트에서만 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action panes` | 분할 화면의 칸 머리 · 툴바 "응답 필요" 를 본다: `--panes=2\|4` 시드의 칸마다 앱 안의 가짜 어댑터(`UI/PreviewPaneAdapter.swift`)로 실행을 보내 첫 칸은 완료, 둘째 칸은 승인 대기, 셋째 칸은 실행 중, 칸에 없는 대화 하나는 질문 대기에 머문다 (실제 실행기를 거친다). 보내기마다 실행 전 스냅샷을 찍어 순서대로 시작하므로 `WAIT=14` 쯤 기다려 찍는다. CLI 를 부르지 않는다. `AHC_DATABASE_PATH` 로 연 DB · 임시 폴더 안의 프로젝트에서만 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action runStatus` | 실행 중 상태 줄의 도는 표시(점 구 `RunOrb`)를 칸 수만큼 함께 돌린다: 열린 칸마다 같은 가짜 어댑터로 생각하는 중 · 명령 실행 중 · 파일 찾는 중 · 답변을 쓰는 중에 머무는 실행을 보낸다 (빈 칸이 있으면 남은 대화를 그 칸에 연다). 모양 확인과 CPU 재기용. 한 칸이면 생각하는 중 하나. CLI 를 부르지 않는다. `AHC_DATABASE_PATH` 로 연 DB · 임시 폴더 안의 프로젝트에서만 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.action stream` · `-preview.wheel "4:up,8:down"` | 응답이 흐르는 동안의 맨 아래 따라가기를 잰다: 선택된 대화에 같은 가짜 어댑터로 긴 Markdown 답을 30ms 마다 몇 글자씩 흘리고(`[흐름]`), 0.1초마다 대화 스크롤 뷰의 맨 아래까지 남은 거리를 `$TMPDIR/ahc-preview/stream.log` 에 적는다. `-preview.wheel` 은 그 초에 휠 한 칸 올림(`up`) · 맨 아래까지 내림(`down`)을 실제 휠과 같은 차례(앱의 휠 감시 → 스크롤 뷰)로 보낸다. `-preview.streamPattern burst` 면 조각을 크게 띄엄띄엄(8 ~ 30글자를 0.15 ~ 0.45초마다) 흘려 고른 속도로 푸는지(`StreamReveal`) 본다. `-preview.streamReplay <파일>` 이면 실제 CLI 에서 기록한 조각(JSON `[[초, 글], …]`)을 같은 때에 같은 글로 다시 흘린다 — 실제와 같은 흐름으로 화면 · CPU 를 잴 때. 인스펙터를 접은 한 칸에서. CLI 를 부르지 않는다. `AHC_DATABASE_PATH` 로 연 DB · 임시 폴더 안의 프로젝트에서만 (`AHC_OFFLINE=1` 일 때만) |
| `-preview.orbTime <초>` · `-preview.orbFPS <n>` | 실행 중 상태 줄의 점 구를 그 엔진 시각에 멈춘다 (원본 렌더와 나란히 보거나 멈춘 기준의 CPU 를 잴 때) · 초당 장면 수를 바꾼다 (기본 60). Debug 빌드 전용 |
| `inttest seed <폴더> --subagents=done` | 끝난 실행 하나(하위 에이전트 둘 · 끝을 보고받지 못한 백그라운드 명령 하나)를 첫 대화에 넣는다 — 대화의 "하위 에이전트" 카드 · 에이전트 탭 확인용. `fanout`(하위 여섯 · 하위가 앞에서 돌린 셸 · 긴 목록)도 있고 쉼표로 함께 줄 수 있다(`--subagents=done,fanout`). `scripts/preview/capture.sh` 의 `SEED_ARGS` 와 `TAB=agents` 로 찍는다 |
| `-inspector.tab changes` · `-inspector.visible YES` · `-window.pane scoreboard` | 창 상태 값을 실행 인자로 덮어쓴다 (탭은 `terminal` · `files` · `pullRequest` · `changes` · `agents`, 옛 값 `branch` 도 변경사항 탭으로 읽는다. 가운데 칸은 `conversation` · `scoreboard` — 옛 값 `대화` · `전적` 도 받는다). `-window.pane review`(옛 값 `크게 보기`)는 대화로 연다 |

Debug 빌드도 번들 ID 가 같으면 실제 앱의 환경설정(창 크기·분할 위치)을 함께 쓴다.
따로 두려면 위 2단계처럼 `PRODUCT_BUNDLE_IDENTIFIER=io.github.jinuklee777.AgentHandoffConsole.preview` 로 빌드한다.
