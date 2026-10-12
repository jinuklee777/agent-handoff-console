#!/usr/bin/env python3
"""기록을 **지금의 `CodexAdapter` 가 읽었다면** 어떻게 되는지 흉내 낸다 (앱 코드 판독 기준, 2026-09-23).

현행 어댑터의 규칙 (스레드 · 턴 ID 로 알림을 거르지 않는다):
  - `turn/completed` 가 오면 **어느 스레드의 것이든** 실행을 끝내고 app-server 를 끈다 (`handleTurnCompleted` → `finishOnce`).
  - `turn/started` 는 어느 스레드의 것이든 `currentTurnID` 를 덮어쓴다 (중단은 메인 스레드 ID + 이 턴 ID 로 보낸다).
  - `item/agentMessage/delta` · 끝난 `agentMessage` 는 어느 스레드의 것이든 화면의 응답이 된다.
  - 사용량은 `CodexUsageAccumulator`: `total.totalTokens` 가 **지금까지 본 값보다 클 때만** `last` 를 더한다
    (스레드마다 total 이 따로이므로 섞이면 일부만 더해진다).

실제 사용량(이 프로세스에서 시작한 턴들의 `last` 합 — 메인 + 하위)과 나란히 보인다. 재개 직후 되풀이되는
이전 턴의 사용량 알림(c13)은 실제에서 뺀다.

    python3 app_view.py <out.jsonl>...
"""
import json, sys

def usage_of(last):
    i, c, w = last.get("inputTokens", 0), last.get("cachedInputTokens", 0), last.get("cacheWriteInputTokens", 0) or 0
    return {"in": max(0, i - c - w), "cached": c, "out": last.get("outputTokens", 0)}

def add(a, b):
    return {k: a.get(k, 0) + b.get(k, 0) for k in ("in", "cached", "out")}

for path in sys.argv[1:]:
    main = None
    ended = None           # (t, 스레드, 상태)
    last_seen = 0
    app_usage = {"in": 0, "cached": 0, "out": 0}
    true_usage = {}        # 스레드 → 합
    seen_totals = {}       # 스레드 → 마지막 total (같은 total 이 두 번 오면 한 번만)
    messages = []          # 앱이 응답으로 보였을 끝난 agentMessage (스레드, 글)
    turn_started = []      # (t, 스레드, 턴)
    started_turns = set()  # 이 프로세스에서 시작한 턴 (스레드 무관)
    for line in open(path):
        o = json.loads(line)
        if o.get("driver") == "main_thread":
            main = o["id"]
        e = o.get("ev")
        if not e or "method" not in e or "id" in e:
            continue
        m, pr, t = e["method"], e.get("params") or {}, o["t"]
        tid = pr.get("threadId")
        if m == "turn/started":
            started_turns.add((pr.get("turn") or {}).get("id"))
        if m == "thread/tokenUsage/updated":
            tu = pr.get("tokenUsage") or {}
            tot = (tu.get("total") or {}).get("totalTokens", 0)
            if pr.get("turnId") in started_turns and seen_totals.get(tid) != tot:
                seen_totals[tid] = tot
                true_usage[tid] = add(true_usage.get(tid, {}), usage_of(tu.get("last") or {}))
            if ended is None and tot > last_seen:
                last_seen = tot
                app_usage = add(app_usage, usage_of(tu.get("last") or {}))
        if ended is not None:
            continue
        if m == "turn/started":
            turn_started.append((t, "M" if tid == main else "sub", (pr.get("turn") or {}).get("id", "")[-6:]))
        if m == "item/completed" and (pr.get("item") or {}).get("type") == "agentMessage":
            messages.append(("M" if tid == main else "sub", (pr["item"].get("text") or "")[:60]))
        if m == "turn/completed":
            ended = (t, "M" if tid == main else "sub", (pr.get("turn") or {}).get("status"))
    total_true = {"in": 0, "cached": 0, "out": 0}
    for v in true_usage.values():
        total_true = add(total_true, v)
    main_true = true_usage.get(main, {})
    print(f"== {path}")
    print(f"  앱이 실행을 끝냈을 때: {ended}")
    print(f"  그때까지 앱이 응답으로 보였을 메시지: {messages}")
    print(f"  앱의 currentTurnID 가 바뀐 순서: {turn_started}")
    print(f"  앱이 기록했을 사용량: {app_usage}")
    print(f"  실제 사용량 — 메인: {main_true} / 메인 + 하위 전체: {total_true} (스레드 {len(true_usage)}개)")
