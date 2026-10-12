#!/usr/bin/env python3
"""out.jsonl 을 사람이 읽을 타임라인으로. 스레드는 짧은 이름(M = 메인, A·B·… = 나타난 순서)으로 줄인다.

글자 조각 알림(`item/agentMessage/delta` · `item/reasoning/*Delta` · `item/commandExecution/outputDelta` 등)은
스레드별 개수만 센다.

    python3 analyze.py <out.jsonl>
"""
import json, sys
from collections import Counter

path = sys.argv[1]
names = {}
deltas = Counter()
DELTA = ("item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta",
         "item/reasoning/summaryPartAdded", "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
         "item/plan/delta", "turn/diff/updated", "item/fileChange/patchUpdated")

def tname(tid):
    if not tid:
        return "-"
    if tid not in names:
        names[tid] = "M" if not names else chr(ord("A") + len(names) - 1)
    return names[tid]

def short(s, n=140):
    s = str(s).replace("\n", "⏎")
    return s if len(s) <= n else s[:n] + "…"

def flush():
    if deltas:
        print("        δ × " + ", ".join(f"{k}:{v}" for k, v in deltas.items()))
        deltas.clear()

def item_brief(it):
    ty = it.get("type")
    if ty == "collabAgentToolCall":
        rs = [tname(x) for x in it.get("receiverThreadIds") or []]
        st = {tname(k): (v.get("status"), short(v.get("message") or "", 60)) for k, v in (it.get("agentsStates") or {}).items()}
        return (f"collab {it.get('tool')} status={it.get('status')} sender={tname(it.get('senderThreadId'))} "
                f"receivers={rs} model={it.get('model')} effort={it.get('reasoningEffort')} "
                f"prompt={short(it.get('prompt') or '', 80)} states={st}")
    if ty == "subAgentActivity":
        return f"subAgentActivity kind={it.get('kind')} agent={tname(it.get('agentThreadId'))} path={it.get('agentPath')}"
    if ty == "commandExecution":
        return (f"cmd status={it.get('status')} exit={it.get('exitCode')} pid={it.get('processId')} src={it.get('source')} "
                f"{short(it.get('command'), 90)} out={short(it.get('aggregatedOutput') or '', 60)}")
    if ty == "agentMessage":
        return f"agentMessage phase={it.get('phase')} {short(it.get('text') or '', 160)}"
    if ty == "userMessage":
        c = it.get("content") or []
        txt = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
        return f"userMessage {short(txt, 120)}"
    if ty == "fileChange":
        return f"fileChange status={it.get('status')} {[c.get('path') for c in it.get('changes') or []]}"
    if ty == "sleep":
        return f"sleep {it.get('durationMs')}ms"
    if ty == "reasoning":
        return "reasoning"
    return f"{ty} {short(json.dumps(it, ensure_ascii=False), 200)}"

for line in open(path):
    o = json.loads(line)
    t = o.get("t")
    if "driver" in o:
        flush()
        d = o["driver"]
        if d == "sent":
            ob = o["obj"]
            m = ob.get("method") or ("response" if "result" in ob or "error" in ob else "?")
            pr = ob.get("params") or ob.get("result") or ob.get("error") or {}
            if isinstance(pr, dict) and "threadId" in pr:
                pr = {**pr, "threadId": tname(pr["threadId"])}
            if isinstance(pr, dict) and "input" in pr:
                pr = {**pr, "input": short(json.dumps(pr["input"], ensure_ascii=False), 60)}
            print(f"{t:7.1f} >> {m} id={ob.get('id')} {short(json.dumps(pr, ensure_ascii=False), 200)}")
        elif d == "main_thread":
            tname(o["id"]); print(f"{t:7.1f} -- main thread = M")
        else:
            extra = {k: v for k, v in o.items() if k not in ("t", "driver", "args", "prompt", "env_keys", "cwd")}
            if "active_turns" in extra:
                extra["active_turns"] = {tname(k): v[-6:] if v else v for k, v in extra["active_turns"].items()}
            print(f"{t:7.1f} -- driver {d} {short(json.dumps(extra, ensure_ascii=False), 300) if extra else ''}")
        continue
    if "raw" in o:
        flush(); print(f"{t:7.1f} RAW {short(o['raw'])}"); continue
    e = o["ev"]
    m = e.get("method")
    pr = e.get("params") or {}
    if m is None:
        flush()
        r = e.get("result", e.get("error"))
        if isinstance(r, dict) and "thread" in r:
            th = r["thread"]
            r = {"thread.id": tname(th.get("id")), "model": r.get("model") or th.get("model"),
                 "effort": r.get("reasoningEffort") or th.get("reasoningEffort"),
                 "parent": tname(th.get("parentThreadId")) if th.get("parentThreadId") else None,
                 "nick": th.get("agentNickname"), "role": th.get("agentRole"), "source": th.get("source"),
                 "status": th.get("status")}
        if isinstance(r, dict) and "data" in r and isinstance(r["data"], list):
            r = {**r, "data": [tname(x) if isinstance(x, str) else x for x in r["data"]]}
        print(f"{t:7.1f} << id={e.get('id')} {short(json.dumps(r, ensure_ascii=False), 260)}")
        continue
    tag = tname(pr.get("threadId")) if "threadId" in pr else "-"
    if m in DELTA:
        deltas[f"{m.split('/')[-1]}[{tag}]"] += 1
        continue
    flush()
    if "id" in e:
        print(f"{t:7.1f} ?? SERVER REQUEST {m} [{tag}] id={e['id']} {short(json.dumps(pr, ensure_ascii=False), 260)}")
        continue
    if m in ("item/started", "item/completed", "item/updated"):
        print(f"{t:7.1f} {m.split('/')[1]:9s} [{tag}] {item_brief(pr.get('item') or {})}")
    elif m == "thread/started":
        th = pr.get("thread") or {}
        print(f"{t:7.1f} thread/started [{tname(th.get('id'))}] parent={tname(th.get('parentThreadId')) if th.get('parentThreadId') else None} "
              f"nick={th.get('agentNickname')} role={th.get('agentRole')} model={th.get('model')} effort={th.get('reasoningEffort')} "
              f"source={short(json.dumps(th.get('source'), ensure_ascii=False), 160)} status={th.get('status')}")
    elif m in ("turn/started", "turn/completed"):
        tu = pr.get("turn") or {}
        print(f"{t:7.1f} {m} [{tag}] turn={str(tu.get('id'))[-6:]} status={tu.get('status')} dur={tu.get('durationMs')} err={short(json.dumps(tu.get('error'), ensure_ascii=False), 80) if tu.get('error') else ''}")
    elif m == "thread/tokenUsage/updated":
        tu = pr.get("tokenUsage") or {}
        tot, last = tu.get("total") or {}, tu.get("last") or {}
        print(f"{t:7.1f} tokenUsage [{tag}] turn={str(pr.get('turnId'))[-6:]} total={tot.get('totalTokens')} last={last.get('totalTokens')} (in={last.get('inputTokens')} cached={last.get('cachedInputTokens')} out={last.get('outputTokens')})")
    elif m == "thread/status/changed":
        print(f"{t:7.1f} status [{tag}] {json.dumps(pr.get('status'), ensure_ascii=False)}")
    elif m == "account/rateLimits/updated":
        rl = pr.get("rateLimits") or {}
        print(f"{t:7.1f} rateLimits primary={(rl.get('primary') or {}).get('usedPercent')}% secondary={(rl.get('secondary') or {}).get('usedPercent')}%")
    elif m in ("hook/started", "hook/completed"):
        print(f"{t:7.1f} {m} [{tag}] {short(json.dumps(pr, ensure_ascii=False), 160)}")
    else:
        print(f"{t:7.1f} {m} [{tag}] {short(json.dumps(pr, ensure_ascii=False), 260)}")
flush()
print("threads:", {v: k for k, v in names.items()})
