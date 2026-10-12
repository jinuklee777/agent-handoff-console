#!/usr/bin/env python3
"""out.jsonl 을 사람이 읽을 타임라인으로. stream_event 조각은 개수만 센다."""
import json, sys
from collections import Counter

path = sys.argv[1]
deltas = Counter()
last_delta_key = None

def short(s, n=140):
    s = s.replace("\n", "⏎")
    return s if len(s) <= n else s[:n] + "…"

def flush():
    global last_delta_key
    if deltas:
        print("        stream_event × " + ", ".join(f"{k}:{v}" for k, v in deltas.items()))
        deltas.clear()
    last_delta_key = None

for line in open(path):
    o = json.loads(line)
    t = o.get("t")
    if "driver" in o:
        flush()
        extra = {k: v for k, v in o.items() if k not in ("t", "driver", "obj", "args", "prompt", "env_keys", "cwd")}
        if o["driver"] == "sent":
            ob = o["obj"]
            desc = ob.get("type")
            if desc == "control_response":
                r = ob["response"]["response"]
                desc += f" {r.get('behavior')} {short(r.get('message',''),60)}"
            elif desc == "control_request":
                desc += " " + ob["request"]["subtype"]
            print(f"{t:7.1f} >> {desc}")
        else:
            print(f"{t:7.1f} -- driver {o['driver']} {extra if extra else ''}")
        continue
    if "raw" in o:
        flush(); print(f"{t:7.1f} RAW {short(o['raw'])}"); continue
    e = o["ev"]
    ty = e.get("type")
    parent = e.get("parent_tool_use_id")
    ptag = f" [parent={parent[-8:]}]" if parent else ""
    if ty == "stream_event":
        se = e.get("event", {})
        key = se.get("type", "?")
        if key == "content_block_delta":
            key += ":" + se.get("delta", {}).get("type", "?")
        key += ptag
        deltas[key] += 1
        continue
    flush()
    if ty == "system":
        st = e.get("subtype")
        info = ""
        if st == "init":
            tools = [x for x in e.get("tools", []) if not x.startswith("mcp__")]
            info = f"model={e.get('model')} perm={e.get('permissionMode')} ver={e.get('claude_code_version')} session={str(e.get('session_id'))[-8:]} tools={tools}"
        else:
            rest = {k: v for k, v in e.items() if k not in ("type", "subtype", "uuid", "session_id")}
            info = short(json.dumps(rest, ensure_ascii=False), 400)
        print(f"{t:7.1f} system/{st}{ptag} {info}")
    elif ty in ("assistant", "user"):
        msg = e.get("message", {})
        content = msg.get("content")
        parts = []
        if isinstance(content, str):
            parts.append("str:" + short(content, 200))
        else:
            for b in content or []:
                bt = b.get("type")
                if bt == "text":
                    parts.append("text:" + short(b.get("text", ""), 160))
                elif bt == "tool_use":
                    inp = b.get("input", {})
                    brief = {k: (short(str(v), 60)) for k, v in inp.items() if k in ("description", "subagent_type", "run_in_background", "file_path", "pattern", "command", "model", "name")}
                    parts.append(f"tool_use:{b.get('name')} id={b.get('id','')[-8:]} {brief}")
                elif bt == "tool_result":
                    c = b.get("content")
                    if isinstance(c, list):
                        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                    parts.append(f"tool_result id={b.get('tool_use_id','')[-8:]} err={b.get('is_error', False)} {short(str(c), 160)}")
                elif bt == "thinking":
                    parts.append("thinking")
                else:
                    parts.append(bt)
        model = f" model={msg.get('model')}" if ty == "assistant" else ""
        print(f"{t:7.1f} {ty}{ptag}{model} " + " | ".join(parts))
    elif ty == "result":
        mu = e.get("modelUsage") or {}
        mus = {k: {"in": v.get("inputTokens"), "out": v.get("outputTokens"), "cost": v.get("costUSD")} for k, v in mu.items()}
        print(f"{t:7.1f} RESULT subtype={e.get('subtype')} is_error={e.get('is_error')} turns={e.get('num_turns')} cost={e.get('total_cost_usd')} session={str(e.get('session_id'))[-8:]} result={short(str(e.get('result')), 160)}")
        print(f"        modelUsage={mus}")
    elif ty == "control_request":
        r = e.get("request", {})
        print(f"{t:7.1f} control_request {r.get('subtype')} tool={r.get('tool_name')} id={e.get('request_id','')[-8:]} keys={sorted(r.keys())} {short(json.dumps(r.get('input', {}), ensure_ascii=False), 120)}")
    else:
        print(f"{t:7.1f} {ty}{ptag} {short(json.dumps(e, ensure_ascii=False), 300)}")
flush()
