#!/bin/bash
# 릴리스 zip 을 만든다 — GitHub Releases 에 올릴 것.
#
# 사용법: scripts/make-release.sh
#   결과: build/release.noindex/AgentHandoffConsole-<버전>.zip 과 SHA256SUMS.txt
#
# - Release 빌드 · 유니버설(arm64 + x86_64) · ad-hoc 서명이다. Developer ID 서명 · 공증은 하지 않는다.
#   Xcode 가 ad-hoc 서명 빌드에 스스로 넣는 디버거 연결 권한(get-task-allow)은 빼고 (CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO), 빠졌는지 본다
#   (받는 사람이 처음 한 번 Gatekeeper 를 넘긴다 — README 의 "Download a release").
# - zip 에는 AgentHandoffConsole.app 과 LICENSE · THIRD_PARTY_NOTICES.md 가 한 폴더에 든다.
# - 버전은 프로젝트의 MARKETING_VERSION, 빌드 번호는 install-app.sh 와 같은 커밋 수다. 얕은 클론이면 멈춘다.
# - 작업 트리가 깨끗해야 하고, 빌드는 임시 폴더에 지금 커밋을 새로 클론해서 한다 — zip 이 커밋 하나와 정확히 같고
#   (폴더 동기화 그룹이라 추적하지 않는 Swift 파일도 앱에 들어간다), 앱 바이너리에 이 Mac 의 홈 폴더 경로가 들어가지 않게.
# - 만든 zip 을 풀어 서명을 다시 검사한다. 빌드한 앱은 LaunchServices 등록을 해제하고 임시 폴더째 지운다.
# - 빌드한 앱을 이 스크립트가 열지는 않는다 — Release 빌드는 늘 사용자의 실제 DB(Application Support)를 연다.
set -euo pipefail
trap 'printf "✗ %s행에서 멈췄다: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/release.noindex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

say() { printf '%s\n' "$*"; }

if [ -n "$(git status --porcelain)" ]; then
  say "✗ 작업 트리에 커밋하지 않은 변경이 있다 — 커밋하거나 치운 뒤 다시 실행하라."
  git status --short
  exit 1
fi
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  say "✗ 얕은 클론이라 빌드 번호(커밋 수)를 셀 수 없다 — git fetch --unshallow 뒤 다시 실행하라."
  exit 1
fi

COMMIT=$(git rev-parse HEAD)
BUILD=$(git rev-list --count HEAD)
VERSION=$(xcodebuild -project AgentHandoffConsole.xcodeproj -scheme AgentHandoffConsole -configuration Release \
  -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
[ -n "$VERSION" ] || { say "✗ MARKETING_VERSION 을 읽지 못했다"; exit 1; }
NAME="AgentHandoffConsole-$VERSION"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ahc-release.XXXXXX")
APP="$WORK/DerivedData.noindex/Build/Products/Release/AgentHandoffConsole.app"
cleanup() {
  if [ -d "$APP" ]; then "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

say "▸ $NAME (빌드 $BUILD, ${COMMIT:0:7}) — 임시 폴더에 클론해 Release 빌드"
git clone --quiet "$ROOT" "$WORK/src"
git -C "$WORK/src" checkout --quiet --detach "$COMMIT"
mkdir -p "$OUT"
LOG="$OUT/build.log"
if ! xcodebuild -project "$WORK/src/AgentHandoffConsole.xcodeproj" -scheme AgentHandoffConsole -configuration Release \
    -derivedDataPath "$WORK/DerivedData.noindex" -onlyUsePackageVersionsFromResolvedFile \
    ONLY_ACTIVE_ARCH=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CURRENT_PROJECT_VERSION="$BUILD" build >"$LOG" 2>&1; then
  grep -E 'error:' "$LOG" | sort -u | head -20 || true
  say "✗ 빌드 실패 — 전체 기록: $LOG"
  exit 1
fi

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || { say "✗ 앱의 버전이 $VERSION 이 아니다"; exit 1; }
[ "$(plist CFBundleVersion)" = "$BUILD" ] || { say "✗ 앱의 빌드 번호가 $BUILD 이 아니다"; exit 1; }
ARCHS=$(lipo -archs "$APP/Contents/MacOS/AgentHandoffConsole")
codesign --verify --deep --strict "$APP"
entitlements=$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)
if grep -q 'get-task-allow' <<<"$entitlements"; then
  say "✗ 앱에 디버거 연결 권한(get-task-allow)이 들어 있다"
  exit 1
fi
home_paths=$(strings -a "$APP/Contents/MacOS/AgentHandoffConsole" | grep -F "$HOME/" || true)
if [ -n "$home_paths" ]; then
  say "✗ 앱 바이너리에 홈 폴더 경로($HOME/)가 들어 있다:"
  printf '%s\n' "$home_paths" | head -5
  exit 1
fi
say "  $(plist CFBundleIdentifier) · $ARCHS · 서명 확인"

STAGE="$WORK/$NAME"
ZIP="$OUT/$NAME.zip"
rm -f "$ZIP"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AgentHandoffConsole.app"
cp "$WORK/src/LICENSE" "$WORK/src/THIRD_PARTY_NOTICES.md" "$STAGE/"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"

# 받은 사람이 푸는 것처럼 풀어 서명을 다시 본다 (zip 이 번들을 깨지 않았는지).
CHECK="$WORK/check"
mkdir -p "$CHECK"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/$NAME/AgentHandoffConsole.app"
for f in LICENSE THIRD_PARTY_NOTICES.md; do
  [ -f "$CHECK/$NAME/$f" ] || { say "✗ zip 에 $f 가 없다"; exit 1; }
done

(cd "$OUT" && shasum -a 256 "$NAME.zip" > SHA256SUMS.txt)
say "✓ $ZIP"
say "  $(cat "$OUT/SHA256SUMS.txt")"
say ""
say "릴리스 초안 (태그는 게시할 때 이 커밋에 생긴다):"
say "  gh release create v$VERSION --draft --target $COMMIT --title v$VERSION --notes-file <노트> \\"
say "    \"$ZIP\" \"$OUT/SHA256SUMS.txt\""
