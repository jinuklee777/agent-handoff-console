#!/bin/bash
# 사용법: capture.sh <시나리오> <결과 이름> [앱 인수...]
# 환경변수: TAB(인스펙터 탭, 기본 changes) WAIT(띄운 뒤 기다릴 초, 기본 4) SIZE(창 크기, 기본 1440x900)
#          SEED_ARGS(seed 에 더할 인수 — 예 "--models --selection=claude:opus:high", 입력창 · 모델 칩 확인용)
#          KEEP=1 이면 캡처 뒤 앱을 끄지 않는다 (같은 창을 여러 번 찍을 때).
#          SEED=none 이면 프로젝트를 seed 하지 않는다 — 빈 DB (첫 실행 점검표). 시나리오 인수는 아무 이름이나 (예: none).
#            점검표의 사실은 앱 인수 -preview.firstRun "claude=nologin,codex=missing,notify=denied,…" 로 준다 (README).
#          INSPECTOR=NO 면 인스펙터를 접는다 (기본 YES).
# 앱 빌드: xcodebuild -project AgentHandoffConsole.xcodeproj -scheme AgentHandoffConsole -configuration Debug \
#   -derivedDataPath build/DerivedData-preview PRODUCT_BUNDLE_IDENTIFIER=io.github.jinuklee777.AgentHandoffConsole.preview build
# 먼저 ./scripts/build-inttest.sh (임시 DB 에 프로젝트를 seed 한다) 와 scenarios.sh 가 필요하다.
# 미리보기 번들 ID 빌드를 AHC_OFFLINE=1 · 임시 DB 로 뒤에서(-g) 띄우고 그 창만 찍는다. 사용자 앱·DB 는 건드리지 않는다.
# 인스펙터는 기본으로 편다 (-inspector.visible YES, INSPECTOR=NO 로 접는다 — 키는 App/WindowState.swift 의 WindowStateKey.inspectorVisible).
# 미리보기 번들의 환경설정에 숨김이 남아 있어도 덮어쓴다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREVIEW_DIR="${PREVIEW_DIR:-${TMPDIR:-/tmp}/ahc-preview}"
SP=$PREVIEW_DIR
# 창 번호 도구는 처음 한 번 컴파일한다.
mkdir -p "$SP/tools"
[ -x "$SP/tools/winid" ] || xcrun swiftc -O -o "$SP/tools/winid" "$ROOT/scripts/preview/winid.swift"
[ -x "$SP/tools/popwin" ] || xcrun swiftc -O -o "$SP/tools/popwin" "$ROOT/scripts/preview/popwin.swift"
APP=$ROOT/build/DerivedData-preview/Build/Products/Debug/AgentHandoffConsole.app
BIN_PATTERN="DerivedData-preview/Build/Products/Debug/AgentHandoffConsole.app/Contents/MacOS/AgentHandoffConsole"
scen=$1; out=$2; shift 2
mkdir -p "$SP/db" "$SP/shots"
DB=$SP/db/$out.sqlite3
rm -f "$DB" "$DB-wal" "$DB-shm"
if [ "${SEED:-}" != "none" ]; then
  dir=$(cat "$SP/repos/$scen.path")
  AHC_DATABASE_PATH=$DB "$ROOT/build/inttest/inttest" seed "$dir" ${SEED_ARGS:-} >/dev/null || { echo "seed 실패"; exit 1; }
fi
pkill -f "$BIN_PATTERN" 2>/dev/null; sleep 0.5
open -g -n -a "$APP" --env AHC_OFFLINE=1 --env "AHC_DATABASE_PATH=$DB" --args \
  -preview.windowSize "${SIZE:-1440x900}" -inspector.tab "${TAB:-changes}" -window.pane 대화 -inspector.visible "${INSPECTOR:-YES}" "$@"
pid=""; wid=0
for _ in $(seq 1 60); do
  pid=$(pgrep -n -f "$BIN_PATTERN")
  if [ -n "$pid" ]; then wid=$("$SP/tools/winid" "$pid"); [ "$wid" != "0" ] && break; fi
  sleep 0.25
done
[ "$wid" = "0" ] && { echo "창을 찾지 못함 (pid=$pid)"; pkill -f "$BIN_PATTERN"; exit 1; }
sleep "${WAIT:-4}"
wid=$("$SP/tools/winid" "$pid")
screencapture -o -x -l "$wid" "$SP/shots/$out.png"
[ "${KEEP:-0}" = "1" ] || pkill -f "$BIN_PATTERN"
echo "$SP/shots/$out.png"
