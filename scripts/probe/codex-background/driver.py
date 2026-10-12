#!/usr/bin/env python3
"""Codex 하위 에이전트 · 백그라운드 작업 실측 드라이버.

앱(CodexAdapter)과 같은 순서 · 같은 기본값으로 `codex app-server --stdio` 를 띄운다:
initialize → initialized → thread/start{cwd, sandbox, approvalPolicy, model} → turn/start{threadId, input, model, effort}.
읽기 전용이면 앱처럼 thread/start 에 `sandbox: read-only` · `approvalPolicy: never`, turn/start 에
`sandboxPolicy: {type: readOnly}` · `approvalPolicy: never` 를 준다.

다른 점: 앱은 `turn/completed` 하나에서 끝내지만(스레드를 가리지 않는다), 여기서는 **메인 스레드의**
`turn/completed` 뒤에도 끄지 않고 알림을 계속 기록한다. 끝내는 때:
  - 메인 턴이 끝난 뒤 진행 중인 턴(어느 스레드든)이 없고 `--quiet` 초 동안 새 줄이 없을 때, 또는
  - 메인 턴이 끝나고 `--post-wait` 초가 지났을 때, 또는 `--timeout`.
그 다음 `thread/loaded/list` 를 한 번 묻고 stdin 을 닫아 종료를 지켜본다.

`--action` 으로 동작 하나를 넣는다:
  - `interrupt_main`  : 메인 턴이 시작되고 `--action-delay` 초 뒤, 메인 턴에 turn/interrupt (턴 진행 중 중단)
  - `interrupt_app_like` : 메인 턴이 시작되고 `--action-delay` 초 뒤, **앱처럼** 메인 스레드 ID + 가장 최근에 받은
                        `turn/started` 의 턴 ID(스레드를 가리지 않는다 — `CodexAdapter` 의 `currentTurnID`)로 turn/interrupt
  - `interrupt_child` : 메인 턴이 끝나고 `--action-delay` 초 뒤, 진행 중인 다른 스레드의 턴마다 turn/interrupt
  - `close_stdin`     : 메인 턴이 끝나고 `--action-delay` 초 뒤 stdin 닫기 (앱이 끝낼 때와 같은 첫 단계)
  - `send_message`    : 메인 턴이 끝나고 `--action-delay` 초 뒤 메인 스레드에 새 turn/start(`--action-text`)
                        (`--action-when children_done` 이면 하위 스레드의 턴까지 모두 끝난 뒤)
  - `inject_shutdown` : (`--action-when children_done` 과 함께) 하위의 최종 답을 `thread/inject_items` 로 메인 기록에
                        developer 메시지로 넣고, 응답을 받은 뒤 `app_shutdown` 과 같은 순서로 끈다 (다음 턴은 --resume 으로)
  - `app_shutdown`    : 메인 턴이 끝나고 `--action-delay` 초 뒤 앱의 `ManagedProcess.shutdown` 과 같은 순서로 끈다
                        (stdin 닫기 → 곧바로 SIGTERM → 3초 뒤 살아 있으면 SIGKILL)

서버 요청(승인 등)은 자동으로 답한다: 명령 · 권한 승인은 거절, 파일 변경은 시험 폴더 안이면 허용,
질문은 빈 답, 모르는 요청은 JSON-RPC 오류 (앱과 같은 원칙: 모르는 요청을 조용히 승인하지 않는다).

환경은 PATH(로그인 셸) · HOME 등 몇 가지와 `CODEX_HOME` 만 넘긴다 (도구 셸의 CLAUDE* · CODEX_* 변수가
섞이지 않게). `TERM=dumb` 은 앱과 같다.

stdout 의 모든 줄을 (경과 초, 원문) 으로 <out>.jsonl 에, stderr 는 <out>.stderr 에 남긴다.
`--watch-proc` 에 준 글자가 든 프로세스를 끝난 뒤 `ps` 로 찾고, `--watch-file` 이 생겼는지
`--watch-after` 초까지 지켜본다 (남는 자식 프로세스 확인).
원문에는 계정 정보가 들어 있을 수 있다 — 저장소에 넣기 전에 sanitize.py 를 거친다.
"""
import argparse, json, os, subprocess, sys, threading, time

p = argparse.ArgumentParser()
p.add_argument("--cwd", required=True)
p.add_argument("--out", required=True)
p.add_argument("--prompt", default="")
p.add_argument("--codex-home", required=True)
p.add_argument("--model", default="gpt-5.6-terra")
p.add_argument("--effort", default="low")
p.add_argument("--sandbox", default="workspace-write")
p.add_argument("--approval-policy", default="on-request")
p.add_argument("--read-only", action="store_true")
p.add_argument("--post-wait", type=float, default=120)
p.add_argument("--quiet", type=float, default=40)
p.add_argument("--timeout", type=float, default=420)
p.add_argument("--path", required=True, help="login shell PATH")
p.add_argument("--action", choices=["none", "interrupt_main", "interrupt_app_like", "interrupt_child", "close_stdin", "send_message", "app_shutdown", "inject_shutdown"], default="none")
p.add_argument("--action-delay", type=float, default=8)
p.add_argument("--action-when", choices=["main_done", "children_done"], default="main_done",
               help="main_done: 메인 턴이 끝난 뒤 / children_done: 메인 턴이 끝나고 하위 스레드의 턴도 모두 끝난 뒤 (--action-delay 초)")
p.add_argument("--action-text", action="append", default=[],
               help="send_message 의 글. 여러 번 주면 메인 턴이 끝날 때마다(--action-delay 초 뒤) 다음 글을 보낸다")
p.add_argument("--watch-proc", default="")
p.add_argument("--watch-file", default="")
p.add_argument("--watch-after", type=float, default=0)
p.add_argument("--resume", default="", help="이 스레드를 thread/resume 으로 재개한다 (앱의 다음 턴과 같다: excludeTurns)")
p.add_argument("--resume-from", default="", help="다른 시험의 out.jsonl 에서 메인 스레드 ID 를 읽어 재개한다")
p.add_argument("--preflight", action="store_true", help="initialize · 한도 조회만 하고 끝낸다")
a = p.parse_args()
if a.resume_from and not a.resume:
    for l in open(a.resume_from):
        o = json.loads(l)
        if o.get("driver") == "main_thread":
            a.resume = o.get("id") or ""

env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG") if k in os.environ}
env["PATH"] = a.path
env["TERM"] = "dumb"
env["CODEX_HOME"] = os.path.expanduser(a.codex_home)

args = ["codex", "app-server", "--stdio"]
t0 = time.monotonic()
out = open(a.out + ".jsonl", "w")
err = open(a.out + ".stderr", "w")
lock = threading.Lock()

def now():
    return round(time.monotonic() - t0, 2)

def log(obj):
    with lock:
        out.write(json.dumps(obj, ensure_ascii=False) + "\n"); out.flush()

log({"t": 0, "driver": "start", "args": args, "cwd": a.cwd, "prompt": a.prompt, "model": a.model,
     "effort": a.effort, "sandbox": a.sandbox, "approval_policy": a.approval_policy, "read_only": a.read_only,
     "action": a.action, "resume": a.resume, "env_keys": sorted(env)})

proc = subprocess.Popen(args, cwd=a.cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True, bufsize=1)

next_id = 0
pending = {}          # id → (method, Event, [result])
main_thread = None
main_turn = None
main_turn_started_at = None
main_first_done_at = None
active_turns = {}     # threadId → turnId (진행 중)
last_turn_started = None  # 스레드를 가리지 않은 마지막 turn/started 의 턴 ID (앱의 currentTurnID)
children_done_at = None   # 하위 스레드의 턴이 하나라도 끝났고 남은 하위 턴이 없어진 마지막 때
main_last_done_at = None  # 메인 턴이 마지막으로 끝난 때
child_answers = {}        # 하위 스레드 → 마지막 final_answer 글
agent_paths = {}          # 하위 스레드 → agentPath (메인의 subAgentActivity 에서)
last_line_at = time.monotonic()
stdin_open = True

def write(obj):
    global stdin_open
    if not stdin_open:
        log({"t": now(), "driver": "send_skipped_stdin_closed", "obj": obj}); return False
    try:
        proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n"); proc.stdin.flush()
        log({"t": now(), "driver": "sent", "obj": obj}); return True
    except Exception as e:
        log({"t": now(), "driver": "send_failed", "error": str(e)}); return False

def rpc(method, params, wait=True, timeout=60):
    global next_id
    with lock:
        next_id += 1; rid = next_id
    ev = threading.Event(); box = []
    pending[rid] = (method, ev, box)
    write({"method": method, "id": rid, "params": params})
    if not wait:
        return None
    if not ev.wait(timeout):
        log({"t": now(), "driver": "rpc_timeout", "method": method}); return None
    return box[0] if box else None

def inside(path):
    full = os.path.realpath(os.path.join(a.cwd, path))
    return full == os.path.realpath(a.cwd) or full.startswith(os.path.realpath(a.cwd) + os.sep)

def answer_server_request(obj):
    method, rid, params = obj["method"], obj["id"], obj.get("params") or {}
    if method in ("item/commandExecution/requestApproval", "execCommandApproval"):
        write({"id": rid, "result": {"decision": "decline"}})
    elif method in ("item/fileChange/requestApproval", "applyPatchApproval"):
        # 변경 경로는 승인 요청이 아니라 item 에 있다. 요청에 경로가 있으면 보고, 없으면 거절.
        paths = [c.get("path") for c in (params.get("changes") or []) if isinstance(c, dict)]
        ok = bool(paths) and all(inside(x) for x in paths if x)
        write({"id": rid, "result": {"decision": "accept" if ok else "decline"}})
    elif method == "item/tool/requestUserInput":
        write({"id": rid, "result": {"answers": {}}})
    elif method == "mcpServer/elicitation/request":
        write({"id": rid, "result": {"action": "decline", "content": {}}})
    else:
        write({"id": rid, "error": {"code": -32601, "message": f"probe driver does not handle {method}"}})

def reader():
    global main_turn, main_turn_started_at, main_first_done_at, last_line_at, last_turn_started, children_done_at, main_last_done_at
    for line in proc.stdout:
        t = now()
        last_line_at = time.monotonic()
        line = line.rstrip("\n")
        try:
            obj = json.loads(line)
        except Exception:
            log({"t": t, "raw": line}); continue
        log({"t": t, "ev": obj})
        method = obj.get("method")
        if method is None and "id" in obj:
            entry = pending.pop(obj["id"], None)
            if entry:
                entry[2].append(obj); entry[1].set()
            continue
        if method is not None and "id" in obj:
            answer_server_request(obj); continue
        params = obj.get("params") or {}
        tid = params.get("threadId")
        turn = params.get("turn") or {}
        if method == "turn/started" and tid:
            active_turns[tid] = turn.get("id")
            last_turn_started = turn.get("id")
            if tid == main_thread:
                main_turn = turn.get("id")
                if main_turn_started_at is None:
                    main_turn_started_at = time.monotonic()
        elif method == "item/completed" and tid:
            it = params.get("item") or {}
            if it.get("type") == "agentMessage" and it.get("phase") == "final_answer" and tid != main_thread:
                child_answers[tid] = it.get("text") or ""
            if it.get("type") == "subAgentActivity" and it.get("agentThreadId"):
                agent_paths[it["agentThreadId"]] = it.get("agentPath")
        elif method == "turn/completed" and tid:
            active_turns.pop(tid, None)
            if tid == main_thread:
                main_last_done_at = time.monotonic()
                if main_first_done_at is None:
                    main_first_done_at = time.monotonic()
            if tid != main_thread and not any(k != main_thread for k in active_turns):
                children_done_at = time.monotonic()
    log({"t": now(), "driver": "stdout_eof"})

def ereader():
    for line in proc.stderr:
        err.write(f"{time.monotonic() - t0:8.2f} {line}"); err.flush()

threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=ereader, daemon=True).start()

rpc("initialize", {"clientInfo": {"name": "AgentHandoffConsole", "version": "0.1.0", "title": "Agent Handoff Console"}})
write({"method": "initialized", "params": {}})
rpc("account/rateLimits/read", {})

reason = "timeout"
if a.preflight:
    reason = "preflight"
else:
    tparams = {"cwd": os.path.realpath(a.cwd),
               "sandbox": "read-only" if a.read_only else a.sandbox,
               "approvalPolicy": "never" if a.read_only else a.approval_policy,
               "model": a.model}
    if a.resume:
        tparams["threadId"] = a.resume
        tparams["excludeTurns"] = True
    res = rpc("thread/resume" if a.resume else "thread/start", tparams)
    main_thread = (((res or {}).get("result") or {}).get("thread") or {}).get("id")
    log({"t": now(), "driver": "main_thread", "id": main_thread})
    turn = {"threadId": main_thread, "input": [{"type": "text", "text": a.prompt}], "model": a.model}
    if a.effort:
        turn["effort"] = a.effort
    if a.read_only:
        turn["sandboxPolicy"] = {"type": "readOnly"}
        turn["approvalPolicy"] = "never"
    rpc("turn/start", turn, wait=False)

    action_done = a.action == "none"
    pending_texts, sent_at = [], 0.0
    while True:
        tnow = time.monotonic()
        if not action_done:
            fire = False
            if a.action in ("interrupt_main", "interrupt_app_like"):
                fire = main_turn_started_at is not None and tnow - main_turn_started_at >= a.action_delay
            elif a.action_when == "children_done":
                fire = (main_first_done_at is not None and children_done_at is not None
                        and not any(k != main_thread for k in active_turns)
                        and tnow - max(main_first_done_at, children_done_at) >= a.action_delay)
            else:
                fire = main_first_done_at is not None and tnow - main_first_done_at >= a.action_delay
            if fire:
                action_done = True
                log({"t": now(), "driver": "action", "action": a.action, "active_turns": dict(active_turns)})
                if a.action == "interrupt_main" and main_turn:
                    rpc("turn/interrupt", {"threadId": main_thread, "turnId": main_turn}, wait=False)
                elif a.action == "interrupt_app_like" and last_turn_started:
                    rpc("turn/interrupt", {"threadId": main_thread, "turnId": last_turn_started}, wait=False)
                elif a.action == "interrupt_child":
                    for ctid, cturn in list(active_turns.items()):
                        if ctid != main_thread and cturn:
                            rpc("turn/interrupt", {"threadId": ctid, "turnId": cturn}, wait=False)
                elif a.action == "close_stdin":
                    try: proc.stdin.close()
                    except Exception: pass
                    stdin_open = False
                elif a.action == "inject_shutdown":
                    # Codex 가 스스로 넣는 형식(Message Type: FINAL_ANSWER …)을 흉내 낸 developer 메시지.
                    items = [{"type": "message", "role": "developer", "content": [{"type": "input_text", "text":
                              f"Message Type: FINAL_ANSWER\nTask name: /root\nSender: {agent_paths.get(ctid, ctid)}\nPayload:\n{text}"}]}
                             for ctid, text in child_answers.items()]
                    rpc("thread/inject_items", {"threadId": main_thread, "items": items}, timeout=20)
                    time.sleep(1)
                    try: proc.stdin.close()
                    except Exception: pass
                    stdin_open = False
                    proc.terminate()
                    log({"t": now(), "driver": "sigterm"})
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        proc.kill(); log({"t": now(), "driver": "sigkill"})
                elif a.action == "app_shutdown":
                    try: proc.stdin.close()
                    except Exception: pass
                    stdin_open = False
                    proc.terminate()
                    log({"t": now(), "driver": "sigterm"})
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        proc.kill(); log({"t": now(), "driver": "sigkill"})
                elif a.action == "send_message":
                    rpc("turn/start", {"threadId": main_thread, "input": [{"type": "text", "text": a.action_text[0]}],
                                       "model": a.model}, wait=False)
                    pending_texts = a.action_text[1:]
                    sent_at = time.monotonic()
        # 나머지 글: 앞 글의 메인 턴이 끝나고 --action-delay 초 뒤에 하나씩.
        if action_done and a.action == "send_message" and pending_texts and main_thread not in active_turns \
                and main_last_done_at is not None and main_last_done_at > sent_at and tnow - main_last_done_at >= a.action_delay:
            log({"t": now(), "driver": "action", "action": "send_message(next)", "active_turns": dict(active_turns)})
            rpc("turn/start", {"threadId": main_thread, "input": [{"type": "text", "text": pending_texts[0]}],
                               "model": a.model}, wait=False)
            pending_texts = pending_texts[1:]
            sent_at = time.monotonic()
        if proc.poll() is not None:
            reason = "exited_by_itself"; break
        if main_first_done_at is not None:
            if tnow - main_first_done_at >= a.post_wait:
                reason = "post_wait_elapsed"; break
            if action_done and not pending_texts and not active_turns and tnow - last_line_at >= a.quiet:
                reason = "quiet"; break
        if tnow - t0 >= a.timeout:
            break
        time.sleep(0.5)

log({"t": now(), "driver": "phase_end", "reason": reason, "active_turns": dict(active_turns)})
if proc.poll() is None and stdin_open:
    if not a.preflight:
        loaded = rpc("thread/loaded/list", {}, timeout=10)
        # 스레드마다 모델 · 강도 · 부모 · 출처를 남긴다 (하위 스레드는 thread/started 가 오지 않는다 — c1 실측).
        for ltid in (((loaded or {}).get("result") or {}).get("data") or []):
            rpc("thread/read", {"threadId": ltid, "includeTurns": False}, timeout=10)
    try: proc.stdin.close()
    except Exception: pass
    stdin_open = False
    log({"t": now(), "driver": "stdin_closed"})
if proc.poll() is None:
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill()
        log({"t": now(), "driver": "terminated"})
time.sleep(1)
log({"t": now(), "driver": "exited", "returncode": proc.returncode})

def watch():
    procs = ""
    if a.watch_proc:
        procs = subprocess.run(["ps", "-axo", "pid,ppid,command"], capture_output=True, text=True).stdout
        procs = "\n".join(l for l in procs.splitlines() if a.watch_proc in l and "driver.py" not in l and "grep" not in l)
    f = os.path.exists(os.path.join(a.cwd, a.watch_file)) if a.watch_file else None
    return procs, f

if a.watch_proc or a.watch_file:
    procs, f = watch()
    log({"t": now(), "driver": "watch", "when": "after_exit", "procs": procs, "file_exists": f})
    if a.watch_after > 0:
        time.sleep(a.watch_after)
        procs, f = watch()
        log({"t": now(), "driver": "watch", "when": f"after_exit+{a.watch_after:g}s", "procs": procs, "file_exists": f})
log({"t": now(), "driver": "done"})
