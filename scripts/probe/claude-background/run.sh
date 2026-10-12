#!/bin/bash
# Claude Code 서브에이전트 · 백그라운드 작업 실측. **실제 CLI 를 부르고 구독 사용량을 쓴다** (8개 합쳐 API 환산 약 1.7달러, 2026-09-22).
#
#   ./run.sh set1     # t1~t4: 일반 Agent 병렬 · 백그라운드 Agent · ultracode · 읽기 전용 + Agent
#   ./run.sh set2     # t5~t8: 백그라운드 대기 중 stop_task · interrupt · stdin 닫기 · 새 메시지
#   ./run.sh all
#
# 원본은 $OUT(기본: $TMPDIR/claude-background-probe) 에 남는다 — 계정 정보가 들어 있으니 저장소에 넣지 말고
#   python3 sanitize.py "$OUT" logs      로 거른 뒤 넣는다.
#   python3 analyze.py "$OUT/t2/out.jsonl"   으로 타임라인을 본다.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/claude-background-probe}"
MODEL="${MODEL:-claude-sonnet-5}"
mkdir -p "$OUT"
cd "$OUT"

# 앱과 같은 조건: 로그인 셸의 PATH 만. 도구 셸의 CLAUDE* · ANTHROPIC_* 변수는 넘기지 않는다 (driver.py 가 환경을 새로 짠다).
LOGIN_PATH="$(env -i HOME="$HOME" USER="$USER" zsh -lc 'echo $PATH' 2>/dev/null)"

fixture() {  # 시험 폴더: 첫 줄이 다른 txt 세 개
    mkdir -p "$1/work"
    printf 'alpha first line\nalpha second\n' > "$1/work/alpha.txt"
    printf 'beta first line\nbeta second\n' > "$1/work/beta.txt"
    printf 'gamma first line\ngamma second\n' > "$1/work/gamma.txt"
}
drive() { python3 "$HERE/driver.py" --path "$LOGIN_PATH" --model "$MODEL" "$@"; }

set1() {
    local T1='This is a protocol test. In a SINGLE assistant message, call the Agent tool TWICE in parallel (do not set run_in_background):
1) subagent_type "Explore", description "count txt files", prompt "Use the Glob tool to find *.txt files in the current directory. Reply with just the number."
2) subagent_type "general-purpose", description "read alpha", prompt "Use the Read tool to read alpha.txt in the current directory. Reply with its first line only."
After both finish, reply with exactly one line: count=<n>, first=<line>. Do not use any other tools yourself.'
    local T2='This is a protocol test. Call the Agent tool exactly once with run_in_background set to true, subagent_type "general-purpose", description "slow read", prompt "Use the Read tool to read beta.txt, then read gamma.txt, then reply with both first lines." Right after launching it, end your turn by replying exactly: launched. Do not wait for it. When you are later notified that it finished, reply with: bg-done: followed by its result.'
    local T3='ultracode 이 폴더의 txt 파일 세 개(alpha.txt, beta.txt, gamma.txt)를 각각 다른 에이전트가 읽고 첫 줄을 요약하게 한 다음, 결과를 한 줄씩 모아서 알려줘. 파일은 수정하지 마.'
    local T4='This is a test of tool restrictions in a sandboxed scratch folder. Call the Agent tool once with subagent_type "general-purpose", description "write probe", prompt "Create a file named probe.txt in the current directory containing the word PROBE, using whatever file-writing tool you have. Then report exactly which tool you used, or state that you had no tool able to write files." Then report the subagent answer verbatim.'
    for t in t1 t2 t3 t4; do fixture "$t"; done
    drive --cwd t1/work --out t1/out --prompt "$T1" --post-wait 45 --timeout 300 &
    drive --cwd t2/work --out t2/out --prompt "$T2" --post-wait 240 --timeout 420 &
    drive --cwd t3/work --out t3/out --prompt "$T3" --post-wait 300 --timeout 720 &
    drive --cwd t4/work --out t4/out --prompt "$T4" --read-only --post-wait 30 --timeout 300 &
    wait
    echo "t4 에 probe.txt 가 생겼는가: $([ -e t4/work/probe.txt ] && echo 예 || echo 아니오)"
}

set2() {
    # 서브에이전트에게 `sleep 40` 을 시킨다. CLI 가 단독 sleep 을 막아 서브에이전트가 백그라운드 셸로 다시 띄우는 일이 잦다
    # (2026-09-22) — 그래서 "서브에이전트 소유 작업"도 함께 관찰된다.
    local BG='This is a protocol test. Call the Agent tool exactly once with run_in_background set to true, subagent_type "general-purpose", description "sleeper", prompt "Run the Bash command: sleep 40 (in the foreground, not in background). Then reply with: slept." Right after launching it, end your turn by replying exactly: launched. Do not wait for it. When you are later notified that it finished, reply with: bg-done: followed by its result.'
    for t in t5 t6 t7 t8; do fixture "$t"; done
    drive --cwd t5/work --out t5/out --prompt "$BG" --action stop_task --action-delay 8 --post-wait 90 --timeout 240 &
    drive --cwd t6/work --out t6/out --prompt "$BG" --action interrupt --action-delay 8 --post-wait 90 --timeout 240 &
    drive --cwd t7/work --out t7/out --prompt "$BG" --action close_stdin --action-delay 8 --post-wait 120 --timeout 240 &
    drive --cwd t8/work --out t8/out --prompt "$BG" --action send_message --action-text "Reply with exactly: pong. Do not call any tools." --action-delay 8 --post-wait 120 --timeout 240 &
    wait
}

case "${1:-}" in
    set1) set1 ;;
    set2) set2 ;;
    all) set1; set2 ;;
    *) echo "사용법: $0 set1|set2|all" >&2; exit 2 ;;
esac
echo "원본: $OUT/t*/out.jsonl"
