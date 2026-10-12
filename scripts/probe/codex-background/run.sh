#!/bin/bash
# Codex 하위 에이전트 · 백그라운드 작업 실측. **실제 CLI 를 부르고 구독 사용량을 쓴다.**
# Claude 쪽 실측(../claude-background)의 t1~t8 에 대응하는 시험이다.
#
#   CODEX_HOME_PROBE=~/.codex-accounts/account2 ./run.sh set1   # c1~c4: 병렬 하위 에이전트 · 안 기다리는 하위 에이전트 · ultra · 읽기 전용
#   ./run.sh set2     # c5~c8: 백그라운드 터미널 · 기다리는 중 중단 · 대기 중 stdin 닫기 · 대기 중 새 메시지
#   ./run.sh set3     # c9~c12: 백그라운드 터미널 + 앱처럼 끄기 · 대기 중 하위 스레드 중단 · 하위 에이전트 + 앱처럼 끄기 ·
#                     #         하위 에이전트를 기다리는 중 앱처럼 중단(메인 스레드 + 하위 턴 ID)
#                     # 이어서 c13: c11 의 메인 스레드를 새 프로세스에서 재개해 하위 에이전트의 상태를 묻는다 (앱의 다음 턴)
#   ./run.sh set4     # c14 · c15 · c16: 기다리지 않은 하위가 끝난 뒤 메인이 그 결과를 아는가
#                     #   (같은 프로세스의 다음 턴 · 끄고 재개한 새 프로세스 · 같은 프로세스의 다다음 턴)
#                     # c17: 하위가 끝나면 그 답을 thread/inject_items 로 메인 기록에 넣고 끈 뒤, 재개해 묻는다
#   ./run.sh all
#
# 원본은 $OUT(기본: $TMPDIR/codex-background-probe) 에 남는다 — 계정 정보가 들어 있으니 저장소에 넣지 말고
#   python3 sanitize.py "$OUT" logs      로 거른 뒤 넣는다.
#   python3 analyze.py "$OUT/c2/out.jsonl"   으로 타임라인을 본다.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/codex-background-probe}"
MODEL="${MODEL:-gpt-5.6-terra}"
EFFORT="${EFFORT:-low}"
CODEX_HOME_PROBE="${CODEX_HOME_PROBE:-$HOME/.codex}"
mkdir -p "$OUT"
cd "$OUT"

# 앱과 같은 조건: 로그인 셸의 PATH 만. 도구 셸의 CLAUDE* · CODEX_* 변수는 넘기지 않는다 (driver.py 가 환경을 새로 짠다).
LOGIN_PATH="$(env -i HOME="$HOME" USER="$USER" zsh -lc 'echo $PATH' 2>/dev/null)"

fixture() {  # 시험 폴더: 첫 줄이 다른 txt 세 개
    rm -rf "$1/work"; mkdir -p "$1/work"
    printf 'alpha first line\nalpha second\n' > "$1/work/alpha.txt"
    printf 'beta first line\nbeta second\n' > "$1/work/beta.txt"
    printf 'gamma first line\ngamma second\n' > "$1/work/gamma.txt"
}
drive() { python3 "$HERE/driver.py" --path "$LOGIN_PATH" --codex-home "$CODEX_HOME_PROBE" --model "$MODEL" "$@"; }

# 메인이 기다리지 않는 하위 에이전트 하나. $1 = sleep 초 (시험마다 달리 해서 남은 프로세스를 ps 로 찾는다).
bg_prompt() {
    echo "This is a protocol test of your multi-agent tools. Using your sub-agent tools, spawn exactly ONE sub-agent with this task: \"Run the shell command \`sleep $1 && echo child > child.txt\` in the foreground and wait for it to finish. Then read beta.txt and reply with its first line.\" Do NOT wait for the sub-agent and do not check on it. Right after spawning it, end your turn by replying exactly: launched. If you are later told that it finished, reply with: bg-done: followed by its result."
}
# 백그라운드 터미널(unified exec). $1 = sleep 초.
term_prompt() {
    echo "This is a protocol test of background terminals. Start the shell command \`sleep $1 && echo done > marker.txt\` with your command tool using a short yield time (about 1 second), so that it keeps running as a background terminal session. Do not wait for it, do not poll it, and do not use nohup, & or disown. Then immediately end your turn by replying exactly: started."
}

set1() {
    local C1='This is a protocol test of your multi-agent tools. Using your sub-agent tools, spawn TWO sub-agents in parallel:
1) task: "Run `ls *.txt | wc -l` in the current directory and reply with just the number."
2) task: "Read alpha.txt in the current directory and reply with its first line only."
Then wait for both to finish. Finally reply with exactly one line: count=<n>, first=<line>. Do not run any commands yourself.'
    local C3='이 폴더의 txt 파일 세 개(alpha.txt, beta.txt, gamma.txt)를 각각 다른 에이전트가 읽고 첫 줄을 요약하게 한 다음, 결과를 한 줄씩 모아서 알려줘. 파일은 수정하지 마.'
    local C4='This is a test of tool restrictions in a sandboxed scratch folder. Using your sub-agent tools, spawn ONE sub-agent with this task: "Create a file named probe.txt in the current directory containing the word PROBE, using whatever tool you have. Then report exactly which tool you used and whether it succeeded, or state that you could not write files." Wait for it to finish, then report the sub-agent answer verbatim.'
    for t in c1 c2 c3 c4; do fixture "$t"; done
    drive --cwd c1/work --out c1/out --effort "$EFFORT" --prompt "$C1" --post-wait 60 --quiet 20 --timeout 300 &
    drive --cwd c2/work --out c2/out --effort "$EFFORT" --prompt "$(bg_prompt 20)" --post-wait 150 --quiet 45 --timeout 420 &
    drive --cwd c3/work --out c3/out --effort ultra --prompt "$C3" --post-wait 150 --quiet 45 --timeout 600 &
    drive --cwd c4/work --out c4/out --effort "$EFFORT" --read-only --prompt "$C4" --post-wait 60 --quiet 20 --timeout 300 &
    wait
    echo "c4 에 probe.txt 가 생겼는가: $([ -e c4/work/probe.txt ] && echo 예 || echo 아니오)"
}

set2() {
    local C8MSG='Reply with exactly: pong. Do not call any tools.'
    local C6="This is a protocol test of your multi-agent tools. Using your sub-agent tools, spawn exactly ONE sub-agent with this task: \"Run the shell command \`sleep 42 && echo child > child.txt\` in the foreground and wait for it to finish. Then reply: slept.\" Then wait for the sub-agent to finish, and finally reply exactly: child-done."
    for t in c5 c6 c7 c8; do fixture "$t"; done
    drive --cwd c5/work --out c5/out --effort "$EFFORT" --prompt "$(term_prompt 45)" --post-wait 80 --quiet 70 --timeout 300 \
          --watch-proc "sleep 45" --watch-file marker.txt &
    drive --cwd c6/work --out c6/out --effort "$EFFORT" --prompt "$C6" --action interrupt_main --action-delay 15 --post-wait 80 --quiet 60 --timeout 300 \
          --watch-proc "sleep 42" --watch-file child.txt --watch-after 45 &
    drive --cwd c7/work --out c7/out --effort "$EFFORT" --prompt "$(bg_prompt 41)" --action close_stdin --action-delay 8 --post-wait 60 --timeout 300 \
          --watch-proc "sleep 41" --watch-file child.txt --watch-after 50 &
    drive --cwd c8/work --out c8/out --effort "$EFFORT" --prompt "$(bg_prompt 43)" --action send_message --action-text "$C8MSG" --action-delay 8 --post-wait 150 --quiet 45 --timeout 420 &
    wait
}

set3() {
    local C12="This is a protocol test of your multi-agent tools. Using your sub-agent tools, spawn exactly ONE sub-agent with this task: \"Run the shell command \`sleep 48 && echo child > child.txt\` in the foreground and wait for it to finish. Then reply: slept.\" Then wait for the sub-agent to finish, and finally reply exactly: child-done."
    for t in c9 c10 c11 c12; do fixture "$t"; done
    drive --cwd c9/work --out c9/out --effort "$EFFORT" --prompt "$(term_prompt 46)" --action app_shutdown --action-delay 0 --post-wait 30 --timeout 300 \
          --watch-proc "sleep 46" --watch-file marker.txt --watch-after 55 &
    drive --cwd c11/work --out c11/out --effort "$EFFORT" --prompt "$(bg_prompt 47)" --action app_shutdown --action-delay 0 --post-wait 30 --timeout 300 \
          --watch-proc "sleep 47" --watch-file child.txt --watch-after 55 &
    drive --cwd c10/work --out c10/out --effort "$EFFORT" --prompt "$(bg_prompt 44)" --action interrupt_child --action-delay 8 --post-wait 90 --quiet 40 --timeout 300 \
          --watch-proc "sleep 44" --watch-file child.txt --watch-after 45 &
    drive --cwd c12/work --out c12/out --effort "$EFFORT" --prompt "$C12" --action interrupt_app_like --action-delay 15 --post-wait 80 --quiet 60 --timeout 300 \
          --watch-proc "sleep 48" --watch-file child.txt --watch-after 45 &
    wait
    local C13='The sub-agent you spawned in the previous turn: what is its status now? Check it with your sub-agent tools (for example by waiting on it for at most 30 seconds) and report exactly what you observe. Do not spawn new agents and do not run shell commands.'
    mkdir -p c13
    drive --cwd c11/work --out c13/out --effort "$EFFORT" --resume-from c11/out.jsonl --prompt "$C13" --post-wait 60 --quiet 30 --timeout 300 \
          --watch-file child.txt &
    wait
}

set4() {
    # 하위에게 추측할 수 없는 값을 만들게 하고, 끝난 뒤 메인에게 도구 없이 맥락만으로 묻는다.
    local SPAWN='This is a protocol test of your multi-agent tools. Using your sub-agent tools, spawn exactly ONE sub-agent with this task: "Run the shell command `sleep 15 && uuidgen | cut -c1-8` in the foreground and wait for it. Then reply with exactly the 8-character output and nothing else." Do NOT wait for the sub-agent and do not check on it. Right after spawning it, end your turn by replying exactly: launched.'
    local ASK='The sub-agent you launched earlier has finished. What exact 8-character value did it report? Answer only from what is already in your conversation context. Do not call any tools at all (no wait, no agent tools, no shell). If the value is not in your context, reply exactly: UNKNOWN.'
    for t in c14 c15 c16 c17; do fixture "$t"; done
    # c14: 같은 프로세스 — 하위가 끝나고 5초 뒤에 묻는다.
    drive --cwd c14/work --out c14/out --effort "$EFFORT" --prompt "$SPAWN" --action send_message --action-when children_done --action-delay 5 \
          --action-text "$ASK" --post-wait 150 --quiet 25 --timeout 300 &
    # c15: 하위가 끝나고 조용해지면 끈다 (단계 B 를 구현한 앱과 같은 끝) → 새 프로세스에서 재개해 묻는다.
    drive --cwd c15/work --out c15/out --effort "$EFFORT" --prompt "$SPAWN" --post-wait 150 --quiet 20 --timeout 300 &
    # c16: 같은 프로세스 — 하위가 끝난 뒤 아무 메시지 하나, 그다음 턴에 묻는다 (c14 에서 결과가 두 번째 턴 끝에 붙었다).
    drive --cwd c16/work --out c16/out --effort "$EFFORT" --prompt "$SPAWN" --action send_message --action-when children_done --action-delay 5 \
          --action-text "Reply with exactly: ok. Do not call any tools." --action-text "$ASK" --post-wait 200 --quiet 25 --timeout 360 &
    # c17: 하위가 끝나면 그 답을 thread/inject_items 로 메인 기록에 넣고 끈다 (c17r 에서 재개해 묻는다).
    drive --cwd c17/work --out c17/out --effort "$EFFORT" --prompt "$SPAWN" --action inject_shutdown --action-when children_done --action-delay 2 \
          --post-wait 150 --timeout 300 &
    wait
    mkdir -p c15r c17r
    drive --cwd c15/work --out c15r/out --effort "$EFFORT" --resume-from c15/out.jsonl --prompt "$ASK" --post-wait 60 --quiet 20 --timeout 200 &
    drive --cwd c17/work --out c17r/out --effort "$EFFORT" --resume-from c17/out.jsonl --prompt "$ASK" --post-wait 60 --quiet 20 --timeout 200 &
    wait
}

case "${1:-}" in
    set1) set1 ;;
    set2) set2 ;;
    set3) set3 ;;
    set4) set4 ;;
    all) set1; set2; set3; set4 ;;
    *) echo "사용법: $0 set1|set2|set3|set4|all" >&2; exit 2 ;;
esac
echo "원본: $OUT/c*/out.jsonl"
