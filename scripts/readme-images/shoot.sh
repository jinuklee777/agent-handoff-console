#!/bin/bash
# 사용법: shoot.sh <준비된 DB> <결과 이름> [앱 인수...]  → $PREVIEW_DIR/readme/shots/<결과 이름>.png (make.sh 가 부른다)
# 환경변수: WAIT(띄운 뒤 기다릴 초, 기본 5) SIZE(창 크기, 기본 1440x900) TAB(인스펙터 탭, 기본 changes)
#          INSPECTOR(YES/NO, 기본 YES) PANE(가운데 칸, 기본 대화)
# 미리보기 번들 ID 빌드를 AHC_OFFLINE=1 · DB 사본 · 데모 CODEX_HOME 으로 뒤에서(-g) 띄우고 그 창만 찍는다.
# 사용자 앱 · 실제 DB · 실제 ~/.codex 는 건드리지 않는다 (scripts/preview/capture.sh 와 같은 방식).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SP="${PREVIEW_DIR:-${TMPDIR:-/tmp}/ahc-preview}"
WORK="$SP/readme"
APP=$ROOT/build/DerivedData-preview/Build/Products/Debug/AgentHandoffConsole.app
BIN_PATTERN="DerivedData-preview/Build/Products/Debug/AgentHandoffConsole.app/Contents/MacOS/AgentHandoffConsole"
mkdir -p "$SP/tools" "$WORK/shots" "$WORK/run"
[ -x "$SP/tools/winid" ] || xcrun swiftc -O -o "$SP/tools/winid" "$ROOT/scripts/preview/winid.swift"
src=$1; out=$2; shift 2
# 앱이 DB 에 쓰는 것(인계 초안 등)이 다른 장면에 섞이지 않게 장면마다 사본으로 띄운다.
DB=$WORK/run/$out.sqlite3
rm -f "$DB" "$DB-wal" "$DB-shm"
cp "$src" "$DB"
pkill -f "$BIN_PATTERN" 2>/dev/null; sleep 0.5
open -g -n -a "$APP" --env AHC_OFFLINE=1 --env "AHC_DATABASE_PATH=$DB" --env "CODEX_HOME=$WORK/codex-home" --args \
  -preview.windowSize "${SIZE:-1440x900}" -inspector.tab "${TAB:-changes}" -window.pane "${PANE:-대화}" \
  -inspector.visible "${INSPECTOR:-YES}" "$@"
pid=""; wid=0
for _ in $(seq 1 60); do
  pid=$(pgrep -n -f "$BIN_PATTERN")
  if [ -n "$pid" ]; then wid=$("$SP/tools/winid" "$pid"); [ "$wid" != "0" ] && break; fi
  sleep 0.25
done
[ "$wid" = "0" ] && { echo "창을 찾지 못함 (pid=$pid)"; pkill -f "$BIN_PATTERN"; exit 1; }
sleep "${WAIT:-5}"
wid=$("$SP/tools/winid" "$pid")
screencapture -o -x -l "$wid" "$WORK/shots/$out.png"
pkill -f "$BIN_PATTERN"
echo "$WORK/shots/$out.png"
