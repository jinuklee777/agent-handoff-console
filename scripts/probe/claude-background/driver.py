#!/usr/bin/env python3
"""Claude Code 서브에이전트 실측 드라이버.

앱(ClaudeAdapter)과 같은 인수 · 같은 초기화 · 같은 승인 응답 형식으로 `claude -p` 를 띄운다.
다른 점 하나: 앱은 첫 `result` 에서 프로세스를 끄지만, 여기서는 끄지 않고 그 뒤에 오는 것까지
`--post-wait` 초 동안 기록한 다음 stdin 을 닫고 종료를 지켜본다.

`--action` 을 주면 첫 `result` 뒤 `--action-delay` 초에 동작 하나를 한다 (백그라운드 작업 대기 중의 반응 실측):
stop_task(마지막으로 시작한 작업) · interrupt · close_stdin · send_message(`--action-text`).

승인 요청(can_use_tool)은 자동으로 답한다: 시험 폴더 밖 쓰기와 Bash 는 거절(`sleep` 만 허용), 나머지는 허용.
환경은 호출자가 넘긴 PATH 와 HOME 등 몇 가지만 쓴다 (도구 셸의 CLAUDE* 변수가 섞이지 않게 — run.sh 참고).

stdout 의 모든 줄을 (경과 초, 원문) 으로 <out>.jsonl 에, stderr 는 <out>.stderr 에 남긴다.
원문에는 계정 정보가 들어 있다 — 저장소에 넣기 전에 sanitize.py 를 거친다.
"""
import argparse, json, os, subprocess, sys, threading, time, uuid

p = argparse.ArgumentParser()
p.add_argument("--cwd", required=True)
p.add_argument("--out", required=True)
p.add_argument("--prompt", required=True)
p.add_argument("--model", default="claude-sonnet-5")
p.add_argument("--permission-mode", default="manual")
p.add_argument("--read-only", action="store_true")
p.add_argument("--post-wait", type=float, default=30)
p.add_argument("--timeout", type=float, default=300)
p.add_argument("--path", required=True, help="login shell PATH")
p.add_argument("--action", choices=["none","stop_task","interrupt","close_stdin","send_message"], default="none")
p.add_argument("--action-delay", type=float, default=5)
p.add_argument("--action-text", default="")
a = p.parse_args()

args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--include-partial-messages", "--replay-user-messages", "--permission-mode", a.permission_mode,
        "--permission-prompt-tool", "stdio", "--model", a.model]
if a.read_only:
    args += ["--disallowedTools", "Write", "Edit", "NotebookEdit", "Bash"]

env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG") if k in os.environ}
env["PATH"] = a.path
env["TERM"] = "dumb"

t0 = time.monotonic()
out = open(a.out + ".jsonl", "w")
err = open(a.out + ".stderr", "w")
meta = {"args": args, "cwd": a.cwd, "prompt": a.prompt, "env_keys": sorted(env)}
out.write(json.dumps({"t": 0, "driver": "start", **meta}, ensure_ascii=False) + "\n"); out.flush()

proc = subprocess.Popen(args, cwd=a.cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True, bufsize=1)
lock = threading.Lock()
first_result_at = None
results = 0
task_ids = []
action_done = False

def log(obj):
    with lock:
        out.write(json.dumps(obj, ensure_ascii=False) + "\n"); out.flush()

def send(obj):
    try:
        proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n"); proc.stdin.flush()
        log({"t": round(time.monotonic() - t0, 2), "driver": "sent", "obj": obj})
    except Exception as e:
        log({"t": round(time.monotonic() - t0, 2), "driver": "send_failed", "error": str(e)})

def allowed(tool, inp):
    # 시험 폴더 밖을 건드리는 쓰기와 Bash 는 거절한다 (앱은 사람이 누르지만 여기서는 자동).
    if tool == "Bash" and str(inp.get("command", "")).strip().startswith("sleep"):
        return True, ""
    if tool == "Bash":
        return False, "이 시험에서는 Bash 를 쓰지 않습니다. Read · Glob · Grep 을 쓰세요."
    path = inp.get("file_path") or inp.get("notebook_path") or inp.get("path")
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit") and path:
        full = os.path.realpath(os.path.join(a.cwd, path))
        if not full.startswith(os.path.realpath(a.cwd) + os.sep):
            return False, "시험 폴더 밖에는 쓸 수 없습니다."
    return True, ""

def reader():
    global first_result_at, results
    for line in proc.stdout:
        t = round(time.monotonic() - t0, 2)
        line = line.rstrip("\n")
        try:
            obj = json.loads(line)
        except Exception:
            log({"t": t, "raw": line}); continue
        log({"t": t, "ev": obj})
        if obj.get("type") == "system" and obj.get("subtype") == "task_started":
            task_ids.append(obj.get("task_id"))
        if obj.get("type") == "result":
            results += 1
            if first_result_at is None:
                first_result_at = time.monotonic()
        if obj.get("type") == "control_request":
            req = obj.get("request", {})
            if req.get("subtype") == "can_use_tool":
                ok, msg = allowed(req.get("tool_name", ""), req.get("input") or {})
                inner = {"behavior": "allow", "updatedInput": req.get("input")} if ok else {"behavior": "deny", "message": msg}
                send({"type": "control_response",
                      "response": {"subtype": "success", "request_id": obj.get("request_id"), "response": inner}})
            # 다른 제어 요청은 앱처럼 답하지 않는다.
    log({"t": round(time.monotonic() - t0, 2), "driver": "stdout_eof"})

def ereader():
    for line in proc.stderr:
        err.write(f"{time.monotonic() - t0:8.2f} {line}"); err.flush()

threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=ereader, daemon=True).start()

send({"type": "control_request", "request_id": f"init-{uuid.uuid4()}", "request": {"subtype": "initialize"}})
send({"type": "user", "session_id": "", "parent_tool_use_id": None,
      "message": {"role": "user", "content": a.prompt}})

reason = "timeout"
while True:
    now = time.monotonic()
    if a.action != "none" and not action_done and first_result_at is not None and now - first_result_at >= a.action_delay:
        action_done = True
        log({"t": round(now - t0, 2), "driver": "action", "action": a.action, "task_ids": task_ids})
        if a.action == "stop_task" and task_ids:
            send({"type": "control_request", "request_id": f"stop-{uuid.uuid4()}", "request": {"subtype": "stop_task", "task_id": task_ids[-1]}})
        elif a.action == "interrupt":
            send({"type": "control_request", "request_id": f"interrupt-{uuid.uuid4()}", "request": {"subtype": "interrupt"}})
        elif a.action == "close_stdin":
            try: proc.stdin.close()
            except Exception: pass
        elif a.action == "send_message":
            send({"type": "user", "session_id": "", "parent_tool_use_id": None, "message": {"role": "user", "content": a.action_text}})
    if proc.poll() is not None:
        reason = "exited_by_itself"; break
    if first_result_at is not None and now - first_result_at >= a.post_wait:
        reason = "post_wait_elapsed"; break
    if now - t0 >= a.timeout:
        break
    time.sleep(0.5)

log({"t": round(time.monotonic() - t0, 2), "driver": "phase_end", "reason": reason, "results_so_far": results})
if proc.poll() is None:
    try: proc.stdin.close()
    except Exception: pass
    log({"t": round(time.monotonic() - t0, 2), "driver": "stdin_closed"})
    try:
        proc.wait(timeout=90)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill()
        log({"t": round(time.monotonic() - t0, 2), "driver": "terminated"})
time.sleep(1)
log({"t": round(time.monotonic() - t0, 2), "driver": "done", "returncode": proc.returncode, "results": results})
