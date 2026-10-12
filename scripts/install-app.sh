#!/bin/bash
# 앱을 빌드해 ~/Applications/AgentHandoffConsole.app 한 곳에 설치하고 다시 연다.
# 고친 뒤 이것 하나만 실행한다. 빌드 산출물을 찾아 열 필요가 없다.
#
# 사용법: scripts/install-app.sh [--debug] [--no-launch]
#   (인수 없음)   Release 빌드, 이 Mac 의 아키텍처만. 고친 뒤 다시 빌드에 약 40초.
#   --debug       Debug 빌드. 고친 뒤 다시 빌드에 몇 초. 최적화하지 않고 메뉴에 "디버그" 가 붙는다.
#   --no-launch   설치만 하고 열지 않는다.
#
# - 빌드가 실패하면 설치된 앱을 건드리지 않는다.
# - 앱이 실행 중이면 ⌘Q 와 같은 종료 요청을 보낸다. 실행 중인 에이전트 작업이 있으면 앱이 확인을 묻고,
#   취소하면 설치하지 않는다 (다시 실행하면 빌드는 바로 끝난다).
# - 이 앱이 띄운 에이전트 안에서 실행되면 앱을 끄지 않는다 (끄면 그 에이전트도 끝난다).
#   새 빌드를 준비해 두고, 사용자가 앱을 종료하면 뒤에서 교체해 다시 연다.
# - 앱은 부른 쪽(에이전트 세션)의 환경 변수 없이 연다 — Finder 로 연 것처럼 (`open_app`).
# - 빌드 폴더는 build/DerivedData.noindex 다. `.noindex` 라서 Spotlight 에 같은 이름의 앱이 겹쳐 뜨지 않는다.
#   설치 뒤 같은 번들 ID 의 다른 사본(빌드 폴더 · Xcode DerivedData · 작업 트리)은 LaunchServices 등록만 해제해,
#   알림을 누르거나 번들 ID 로 열 때 설치본이 열리게 한다. 파일은 지우지 않는다.
#   설치본의 빌드 번호는 커밋 수다 (1 이상). 그 뒤 확인용 빌드(프로젝트의 기본값 — 빌드 번호 0)가 다시 등록돼도 설치본이 먼저 열린다.
set -euo pipefail
trap 'printf "✗ %s행에서 멈췄다: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/scripts/install-app.sh"
BUNDLE_ID=io.github.jinuklee777.AgentHandoffConsole
DEST="$HOME/Applications/AgentHandoffConsole.app"
DERIVED="$ROOT/build/DerivedData.noindex"
WORK="$DERIVED/Install"                 # 설치 대기본과, 앱 종료를 기다리는 교체 작업의 기록
STAGED="$WORK/AgentHandoffConsole.app"
WAITER_PID="$WORK/waiter.pid"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CONFIG=Release
LAUNCH=1

say() { printf '%s\n' "$*"; }

# 앱을 연다. `open` 은 부른 쪽의 환경을 앱에 그대로 넘긴다 — 에이전트(Claude Code · Codex)가 이 스크립트를 돌리면 그 세션의
# 변수(세션 ID · 메시지 토큰 · CLAUDE_CODE_ENTRYPOINT · ANTHROPIC_BASE_URL …)가 앱에, 앱이 띄우는 CLI 에까지 갔다 (2026-10-07 실측).
# Finder 로 연 것처럼 로그인 세션의 기본 변수만 넘긴다. 사용자가 셸에 둔 PATH · API 키 · 프록시는 앱이 셸에게 따로 묻는다.
open_app() {
  local keep=() name
  for name in HOME USER LOGNAME SHELL TMPDIR SSH_AUTH_SOCK LANG; do
    if [ -n "${!name:-}" ]; then keep+=("$name=${!name}"); fi
  done
  env -i ${keep[@]+"${keep[@]}"} PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open "$@"
}

# 실행 중인 이 앱(번들 ID 기준 — 어느 경로의 사본이든). 한 줄에 "pid<탭>번들 경로".
running_apps() {
  osascript -l JavaScript -e "ObjC.import('AppKit');
    \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$BUNDLE_ID').js
      .map(a => a.processIdentifier + '\t' + a.bundleURL.path.js).join('\n')" 2>/dev/null || true
}

# LaunchServices 에 등록된 이 번들 ID 의 사본들.
registered_copies() {
  osascript -l JavaScript -e "ObjC.import('AppKit');
    \$.NSWorkspace.sharedWorkspace.URLsForApplicationsWithBundleIdentifier('$BUNDLE_ID').js
      .map(u => u.path.js).join('\n')" 2>/dev/null || true
}

# <pid> 가 이 스크립트의 조상인가 — 곧 이 앱이 띄운 에이전트가 실행했는가.
is_ancestor() {
  local target=$1 p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$p" = "$target" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

# 대기본을 설치 위치로 옮기고 다른 사본의 등록을 해제한다. 앱이 꺼진 뒤에만 부른다.
# `install_staged || exit 1` 로 부르면 안에서는 set -e 가 꺼지므로 단계마다 직접 확인한다.
install_staged() {
  local old="$WORK/Previous-$$.app" p
  # 실행 중인 번들은 바꾸지 않는다 (샌드박스 등에서 osascript 가 막혀 실행 중임을 못 봤을 때의 방어).
  if pgrep -qf "^$DEST/Contents/MacOS/"; then
    say "✗ 설치본이 아직 실행 중이라 교체하지 않았다. 앱을 ⌘Q 로 끈 뒤 다시 실행하라."
    return 1
  fi
  mkdir -p "$(dirname "$DEST")" || return 1
  if [ -e "$DEST" ] && ! mv "$DEST" "$old"; then
    say "✗ 설치본을 옮기지 못해 교체하지 않았다"
    return 1
  fi
  if ! mv "$STAGED" "$DEST"; then
    if [ -e "$old" ]; then mv "$old" "$DEST"; fi
    say "✗ 설치 실패 — 이전 설치본을 되돌렸다"
    return 1
  fi
  rm -rf "$old"
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  while IFS= read -r p; do
    if [ -n "$p" ] && [ "$p" != "$DEST" ]; then "$LSREGISTER" -u "$p" >/dev/null 2>&1 || true; fi
  done < <(registered_copies)
}

# 앞서 걸어 둔 "앱 종료 뒤 교체" 를 거둔다 (새 빌드가 그 자리를 대신한다).
stop_waiter() {
  local wp
  [ -f "$WAITER_PID" ] || return 0
  wp=$(cat "$WAITER_PID")
  if ps -o command= -p "$wp" 2>/dev/null | grep -q -- '--after-exit'; then kill "$wp" 2>/dev/null || true; fi
  rm -f "$WAITER_PID"
}

# <pid> 의 앱이 끝나면 교체하고 연다. 앱이 에이전트를 끝낼 때 함께 끝나지 않도록
# 새 세션으로 떼어 내 launchd 아래에 둔다.
start_waiter() {
  ( /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!\n"' \
      /bin/bash "$SELF" --after-exit "$1" "$LAUNCH" </dev/null >"$WORK/waiter.log" 2>&1 &
    echo $! >"$WAITER_PID" )
}

# ⌘Q 와 같은 종료 요청. 실행 중인 에이전트 작업이 있으면 앱이 확인을 묻는다.
quit_app() {
  local out
  say "▸ 실행 중인 앱에 종료 요청 (에이전트 작업이 실행 중이면 앱이 확인을 묻는다)"
  if ! out=$(osascript -e "if application id \"$BUNDLE_ID\" is running then
      with timeout of 600 seconds
        tell application id \"$BUNDLE_ID\" to quit
      end timeout
    end if" 2>&1); then
    case "$out" in
      *-128*) say "✗ 앱에서 종료를 취소 — 설치하지 않았다. 빌드는 준비돼 있어 다시 실행하면 바로 교체한다." ;;
      *-1743*) say "✗ 이 터미널에 앱을 종료할 권한이 없다 (시스템 설정 › 개인정보 보호 및 보안 › 자동화)." \
                   "앱을 ⌘Q 로 직접 끈 뒤 다시 실행하면 된다." ;;
      *) say "✗ 앱을 종료하지 못했다: $out" ;;
    esac
    return 1
  fi
  local _
  for _ in $(seq 1 120); do
    [ -z "$(running_apps)" ] && return 0
    sleep 0.5
  done
  say "✗ 앱이 60초 안에 끝나지 않았다 — 설치하지 않았다."
  return 1
}

# 내부용: start_waiter 가 띄운 교체 작업. 앱이 끝나기를 기다렸다가 설치하고 연다.
if [ "${1:-}" = "--after-exit" ]; then
  app_pid=$2; LAUNCH=$3
  while kill -0 "$app_pid" 2>/dev/null; do sleep 1; done
  rm -f "$WAITER_PID"
  if [ -n "$(running_apps)" ]; then say "$(date '+%F %T') 앱이 다시 실행 중이라 교체하지 않음"; exit 1; fi
  install_staged || exit 1
  say "$(date '+%F %T') 설치: $DEST"
  if [ "$LAUNCH" = 1 ]; then open_app "$DEST"; fi
  exit 0
fi

for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=Debug ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p;}' "$SELF"; exit 0 ;;
    *) say "알 수 없는 인수: $arg (--help 참고)" >&2; exit 2 ;;
  esac
done

# 1. 빌드 — 실패하면 여기서 멈춘다.
mkdir -p "$WORK"
LOG="$DERIVED/install-build.log"
source_desc=""; build_number=""
if branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null); then
  source_desc=" — $branch@$(git -C "$ROOT" rev-parse --short HEAD)"
  changed=$(git -C "$ROOT" status --porcelain -- AgentHandoffConsole AgentHandoffConsole.xcodeproj | wc -l | tr -d ' ')
  [ "$changed" = 0 ] || source_desc="$source_desc + 커밋 안 한 앱 변경 ${changed}개 파일"
  # 빌드 번호 = 커밋 수. LaunchServices 는 번들 ID 로 열 때(알림 클릭 등) 빌드 번호가 높은 사본을 고르므로,
  # 프로젝트 값(0) 그대로인 확인용 빌드가 나중에 등록돼도 설치본이 열린다 (커밋이 하나뿐이어도 1).
  build_number=$(git -C "$ROOT" rev-list --count HEAD)
fi
say "▸ $CONFIG 빌드$source_desc"
started=$(date +%s)
# 설치본은 이 Mac 에서만 쓰므로 이 Mac 의 아키텍처만 빌드한다.
if ! xcodebuild -project "$ROOT/AgentHandoffConsole.xcodeproj" -scheme AgentHandoffConsole \
    -configuration "$CONFIG" -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=YES \
    ${build_number:+CURRENT_PROJECT_VERSION=$build_number} build >"$LOG" 2>&1; then
  # xcodebuild 는 같은 오류를 대소문자만 달리 두 번 찍는다.
  errors=$(grep -E ': (fatal )?error: ' "$LOG" | sort -f -u | head -30 || true)
  if [ -n "$errors" ]; then say "$errors"; else tail -20 "$LOG"; fi
  say "✗ 빌드 실패 — 설치된 앱은 그대로다. 전체 기록: ${LOG#"$ROOT"/}"
  exit 1
fi
say "✓ 빌드 $(( $(date +%s) - started ))초"

# 2. 대기본 준비. 설치본이 이 빌드와 같고 다른 경로의 사본이 떠 있지 않으면 교체하지 않는다.
PRODUCT="$DERIVED/Build/Products/$CONFIG/AgentHandoffConsole.app"
stop_waiter
rm -rf "$STAGED"
apps=$(running_apps)
if [ -d "$DEST" ] && diff -rq "$PRODUCT" "$DEST" >/dev/null 2>&1 \
    && ! printf '%s\n' "$apps" | cut -f2 | grep -v -x -F -e "$DEST" -e '' -q; then
  say "✓ 설치본이 이미 이 빌드다 — 교체하지 않는다"
  if [ "$LAUNCH" = 1 ]; then open_app "$DEST"; fi
  exit 0
fi
ditto "$PRODUCT" "$STAGED"

# 3. 실행 중이면 끄고 교체한다. 이 앱 안의 에이전트가 실행했다면 앱이 끝난 뒤로 미룬다.
if [ -n "$apps" ]; then
  while IFS=$'\t' read -r pid _; do
    if is_ancestor "$pid"; then
      start_waiter "$pid"
      say "• 이 앱 안의 에이전트가 실행해 지금은 앱을 끄지 않았다."
      say "  앱을 종료(⌘Q)하면 새 빌드로 바꿔 다시 연다."
      exit 0
    fi
  done <<<"$apps"
  quit_app || exit 1
fi
install_staged || exit 1
say "✓ 설치: ~/Applications/AgentHandoffConsole.app ($CONFIG)"
if [ "$LAUNCH" = 1 ]; then open_app "$DEST"; say "✓ 열었다"; fi
