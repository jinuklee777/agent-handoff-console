#!/bin/bash
# README 소개 이미지를 다시 만든다 → docs/images/*.png
# 실제 앱(미리보기 번들 ID 의 Debug 빌드)을 AHC_OFFLINE=1 · 임시 DB · 임시 저장소로 띄워 창을 찍고, 문구와 합성한다.
# 사용자 앱 · 실제 DB · CLI 는 건드리지 않는다. 필요한 것: 화면 기록 권한, Google Chrome, python3 + Pillow,
# 1440×900pt 창이 들어가는 화면. 중간 결과는 $PREVIEW_DIR/readme (기본 $TMPDIR/ahc-preview/readme).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/readme-images"
export PREVIEW_DIR="${PREVIEW_DIR:-${TMPDIR:-/tmp}/ahc-preview}"
WORK="$PREVIEW_DIR/readme"
mkdir -p "$WORK/db" "$WORK/shots"

# 합성에 쓸 Pillow 있는 파이썬 (셸마다 python3 가 다를 수 있어 먼저 찾는다). PYTHON=<경로> 로 정할 수 있다.
PY=""
for candidate in "${PYTHON:-}" python3 python3.13 python3.12 python3.11 /usr/bin/python3; do
  [ -n "$candidate" ] && command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import PIL' 2>/dev/null \
    && { PY=$candidate; break; }
done
[ -n "$PY" ] || { echo "Pillow 가 있는 python3 를 찾지 못했습니다 (pip install pillow, 또는 PYTHON=<경로>)"; exit 1; }

echo "1/5 미리보기 앱 빌드"
xcodebuild -project "$ROOT/AgentHandoffConsole.xcodeproj" -scheme AgentHandoffConsole -configuration Debug -quiet \
  -derivedDataPath "$ROOT/build/DerivedData-preview" PRODUCT_BUNDLE_IDENTIFIER=io.github.jinuklee777.AgentHandoffConsole.preview build

echo "2/5 seed 빌드 (앱의 비 UI 소스 = scripts/build-inttest.sh 목록)"
SRCS=$(grep -oE 'AgentHandoffConsole/[A-Za-z0-9_+/-]*\.swift' "$ROOT/scripts/build-inttest.sh")
# 이 Mac 의 아키텍처로 (scripts/build-inttest.sh 와 같다 — Apple silicon 은 arm64, Intel 은 x86_64).
(cd "$ROOT" && xcrun swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" -target "$(uname -m)-apple-macos15.0" \
  -swift-version 5 -Onone -D DEBUG -lsqlite3 -suppress-warnings -o "$WORK/seed" $SRCS "$HERE/seed/main.swift")

# 데모 Codex 홈 — 오프라인 미리보기도 기본 계정 홈의 auth.json 으로 로그인 여부를 보므로, 실제 ~/.codex 의 계정이 화면에 나오지 않게 한다.
# 앱은 토큰을 풀지 않는다 — 이메일 · 플랜은 seed 가 DB 에 넣고(seed/main.swift 의 demoCodex), 여기 account_id 와 같아야 남는다.
mkdir -p "$WORK/codex-home"
b64() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
cat > "$WORK/codex-home/auth.json" <<EOF
{"auth_mode":"chatgpt","tokens":{"id_token":"$(b64 '{"alg":"none"}').$(b64 '{"email":"dev@example.com","exp":1893456000,"https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}').demo","access_token":"demo","account_id":"acct-demo"}}
EOF

echo "3/5 시나리오 저장소 · 임시 DB"
for v in full handoff agents; do
  bash "$HERE/scenario.sh" "readme-$v" >/dev/null
  rm -f "$WORK/db/$v.sqlite3" "$WORK/db/$v.sqlite3-wal" "$WORK/db/$v.sqlite3-shm"
  AHC_DATABASE_PATH="$WORK/db/$v.sqlite3" "$WORK/seed" "$v" "$PREVIEW_DIR/repos/readme-$v"
done

echo "4/5 캡처"
DRAFT="로그인 401 재시도 처리 — 토큰 한 번 갱신 후 재전송"
# 한도 — 오프라인 미리보기는 한도를 조회하지 않으므로 넣어 준다 (형식은 AppModel+Continue.swift 의 PreviewLimitFacts).
# Claude 는 다 찼고 Codex 는 여유 — 툴바 한도 칩 · 한도 도달 줄의 초기화 시각 · 인계 카드의 받는 쪽 사용률에 보인다.
# 카드는 가장 많이 쓴 창을, 칩은 첫 창을 보이므로 Codex 의 주간 값을 5시간보다 낮게 두어 둘 다 12% 가 되게 한다.
LIMITS="claude=1.0@5h+0.42@7d,status=cap;codex=0.12@5h+0.06@7d"
# Antigravity 는 `agy -p /usage --output-format json` 응답 모양 그대로 (docs/CLI프로토콜.md 의 "한도 조회 — agy -p /usage").
# 초기화 시각이 지난 값이 되지 않게 찍을 때마다 지금 기준으로 쓴다. 칩에는 가장 많이 쓴 창(Gemini 주간 19%)이 보인다.
in_utc() { date -u -v+"$1" "+%Y-%m-%dT%H:%M:%SZ"; }
AGY_USAGE="$WORK/agy-usage.json"
cat > "$AGY_USAGE" <<EOF
{"conversation_id":"","status":"SUCCESS","response":"","duration_seconds":0,"num_turns":0,
 "command":{"name":"usage","data":{"groups":[
  {"name":"Gemini Models","buckets":[
   {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.81,"reset_time":"$(in_utc 4d)"},
   {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.93,"reset_time":"$(in_utc 3H)"}]},
  {"name":"Claude and GPT models","buckets":[
   {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"$(in_utc 4d)"},
   {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"$(in_utc 5H)"}]}]}}}
EOF
# 대화는 맨 아래로 스크롤된 채 찍히므로 창 높이가 맨 위에서 잘리는 자리를 정한다 — 툴바 바로 밑에서 Claude 의 머리줄이
# 반쯤 잘리지 않게, 그 위 빈 자리에서 잘리는 높이 (대화 · 창 배치가 바뀌면 hero 의 맨 위를 다시 확인한다).
HERO_SIZE=1440x920
SHOOT="$HERE/shoot.sh"
SIZE=$HERO_SIZE bash "$SHOOT" "$WORK/db/full.sqlite3" hero -preview.commitDraft "$DRAFT" \
  -preview.limits "$LIMITS" -preview.agyUsage "$AGY_USAGE"
SIZE=$HERO_SIZE bash "$SHOOT" "$WORK/db/full.sqlite3" hero-dark -preview.appearance dark -preview.commitDraft "$DRAFT" \
  -preview.limits "$LIMITS" -preview.agyUsage "$AGY_USAGE"
SIZE=1440x720 bash "$SHOOT" "$WORK/db/full.sqlite3" changes \
  -preview.action review:Moa/Auth/AuthTransport.swift -diff.wideMode unified -preview.commitDraft "$DRAFT"
# 인계 카드 — 앱이 카드의 자리를 적어 두면 compose.py 가 그 자리를 자른다 (지난 기록이 남지 않게 먼저 지운다).
rm -f "$WORK/shots/handoff.card.json"
WAIT=6 bash "$SHOOT" "$WORK/db/handoff.sqlite3" handoff -preview.action handoff:codex \
  -preview.cardFrameFile "$WORK/shots/handoff.card.json" -preview.limits "$LIMITS"
bash "$SHOOT" "$WORK/db/agents.sqlite3" agents

echo "5/5 합성 → docs/images"
"$PY" "$HERE/compose.py" "$WORK/shots" "$ROOT/docs/images"
