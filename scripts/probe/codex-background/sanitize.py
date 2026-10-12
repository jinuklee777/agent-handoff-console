#!/usr/bin/env python3
"""driver.py 의 원본 기록 → 저장소에 넣을 기록.

- 버리는 줄: `remoteControl/status/changed`(호스트 이름 · 설치 ID), `mcpServer/startupStatus/updated` ·
  `hook/started` · `hook/completed`(이 실측과 무관하고 환경마다 다르다), `item/reasoning/*` 조각.
- `account/rateLimits/read` 응답에서 계정 ID · 한도 초기화 쿠폰을 지운다 (사용률만 남긴다).
- 요금제 이름(`planType` — 한도 응답 · `account/rateLimits/updated` 알림)은 `<plan>` 으로 바꾼다.
- `thread/*` 의 `gitInfo` 를 지운다.
- 경로를 줄인다: 실행 폴더 → `<probe>`, Codex 홈 → `<codex-home>`, 홈 → `~`, 사용자 이름 → `<user>`,
  호스트 이름 → `<host>`.
- 스레드 · 턴 · 세션(UUID) · 응답 항목(`msg_…` · `rs_…`) · 함수 호출(`call_…`) 식별자는 같은 꼴의 가짜 값으로 바꾼다 —
  실제 계정의 세션 · 응답을 가리킨다. 같은 값은 모든 기록에서 같은 가짜 값이 되고(재개한 시험이 앞 시험의 스레드를 그대로 가리킨다),
  값끼리의 순서도 그대로다.
- 마지막으로 이메일 모양의 글자가 남아 있으면 멈춘다.

    python3 sanitize.py <원본 폴더> <출력 폴더>      # <원본 폴더>/cN/out.jsonl → <출력 폴더>/cN.jsonl
    python3 sanitize.py --rewrite <저장소 logs 폴더>  # 이미 정리한 기록의 식별자를 가짜 값으로 (제자리)
    python3 sanitize.py --check <저장소 logs 폴더>    # 이메일 · 실제 식별자가 남았으면 실패
"""
import json, os, re, socket, sys
from pathlib import Path

DROP = {"remoteControl/status/changed", "mcpServer/startupStatus/updated", "hook/started", "hook/completed",
        "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/reasoning/summaryPartAdded"}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
HEX_ID = re.compile(r"\b(?P<prefix>msg|rs)_(?P<body>[0-9a-f]{40,})\b")
CALL_ID = re.compile(r"\b(?P<prefix>call)_(?P<body>[0-9A-Za-z]{20,})\b")
FAKE_UUID = re.compile(r"[0-9a-f]{8}-0000-[0-9a-f]000-8000-0{12}")
FAKE_CALL = "Fixture"


def is_fake_hex(body):
    return body.startswith("0" * 16)


def is_fake_call(body):
    return body.startswith(FAKE_CALL) and body[len(FAKE_CALL):].isdigit()


class FixtureIds:
    """식별자 → 같은 꼴의 가짜 값 (UUID 는 `0000002a-0000-7000-8000-000000000000` — 판 글자는 그대로, `msg_` · `rs_` 은
    0 으로 채운 16진 번호, `call_` 은 `call_Fixture…` — 길이 그대로). 번호는 넘겨받은 글 전체에서 모은 값의 정렬 순서로 매긴다.
    이미 가짜인 값은 그대로 두고, 새 값은 다음 번호부터 받는다."""

    def __init__(self, texts):
        uuids, hexes, calls = set(), set(), set()
        for text in texts:
            uuids.update(UUID.findall(text))
            hexes.update(match[0] for match in HEX_ID.finditer(text))
            calls.update(match[0] for match in CALL_ID.finditer(text))
        taken = [int(value[:8], 16) for value in uuids if FAKE_UUID.fullmatch(value)]
        fresh = sorted(value for value in uuids if not FAKE_UUID.fullmatch(value))
        self.names = {value: f"{number:08x}-0000-{value[14]}000-8000-000000000000"
                      for number, value in enumerate(fresh, max(taken, default=0) + 1)}
        bodies = {value: HEX_ID.fullmatch(value)["body"] for value in hexes}
        taken = [int(body, 16) for body in bodies.values() if is_fake_hex(body)]
        fresh = sorted(value for value, body in bodies.items() if not is_fake_hex(body))
        for number, value in enumerate(fresh, max(taken, default=0) + 1):
            prefix, body = value.split("_", 1)
            self.names[value] = f"{prefix}_{number:0{len(body)}x}"
        bodies = {value: CALL_ID.fullmatch(value)["body"] for value in calls}
        taken = [int(body[len(FAKE_CALL):]) for body in bodies.values() if is_fake_call(body)]
        fresh = sorted(value for value, body in bodies.items() if not is_fake_call(body))
        for number, value in enumerate(fresh, max(taken, default=0) + 1):
            prefix, body = value.split("_", 1)
            self.names[value] = f"{prefix}_{FAKE_CALL}{str(number).zfill(len(body) - len(FAKE_CALL))}"

    def rename(self, text):
        for pattern in (UUID, HEX_ID, CALL_ID):
            text = pattern.sub(lambda match: self.names.get(match[0], match[0]), text)
        return text


def id_leaks(text):
    """가짜가 아닌 식별자의 수 (값 자체는 돌려주지 않는다)."""
    return (sum(1 for value in UUID.findall(text) if not FAKE_UUID.fullmatch(value))
            + sum(1 for match in HEX_ID.finditer(text) if not is_fake_hex(match["body"]))
            + sum(1 for match in CALL_ID.finditer(text) if not is_fake_call(match["body"])))


def fixture_files(directory):
    files = sorted(Path(directory).glob("c*.jsonl"), key=lambda path: (len(path.stem), path.stem))
    if not files:
        raise ValueError("cN.jsonl 기록이 없습니다")
    return files


def rewrite_fixtures(directory):
    files = fixture_files(directory)
    texts = {path: path.read_text() for path in files}
    ids = FixtureIds(texts.values())
    for path, text in texts.items():
        path.write_text(ids.rename(text))
        print(f"{path.stem}: 식별자를 가짜 값으로")


def check_fixtures(directory):
    for path in fixture_files(directory):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            json.loads(line)
            if EMAIL.search(line) or id_leaks(line):
                # 의심되는 값 자체는 출력하지 않는다.
                sys.exit(f"{path.name}:{number}: 이메일 모양의 글자 · 실제 식별자가 남았습니다")
    print(f"Codex 재생 기록 {len(fixture_files(directory))}개: 공개용 정리 검사 통과")


def strip_limits(r):
    if not isinstance(r, dict):
        return r
    keep = {}
    for k in ("rateLimits", "rateLimitsByLimitId"):
        if k in r:
            keep[k] = r[k]
    keep["_stripped"] = "accountId · rateLimitResetCredits 는 저장소에 넣지 않는다"
    return keep


def strip_git(o):
    if isinstance(o, dict):
        return {k: ("<stripped>" if k == "gitInfo" and v else strip_git(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [strip_git(x) for x in o]
    return o


def strip_plan(o):
    # 요금제 이름은 계정을 좁힌다. 재생 시험은 쓰지 않는다 — 자리만 남긴다.
    if isinstance(o, dict):
        return {k: ("<plan>" if k == "planType" and isinstance(v, str) else strip_plan(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [strip_plan(x) for x in o]
    return o


def sanitize_raw(src, dst):
    os.makedirs(dst, exist_ok=True)
    probe = os.path.realpath(src)
    home = os.path.expanduser("~")
    user = os.path.basename(home)
    hosts = {h for h in {socket.gethostname(), socket.gethostname().split(".")[0]} if h}
    codex_homes = set()

    def clean(text):
        for p in sorted({probe, src.rstrip("/"), probe.replace("/private/", "/", 1)}, key=len, reverse=True):
            text = text.replace(p, "<probe>")
        for h in sorted(codex_homes, key=len, reverse=True):
            text = text.replace(h, "<codex-home>")
        text = text.replace(home, "~")
        for h in sorted(hosts, key=len, reverse=True):
            text = text.replace(h, "<host>")
        return re.sub(r"\b" + re.escape(user) + r"\b", "<user>", text) if user else text

    runs = {}
    for name in sorted(os.listdir(src), key=lambda s: (len(s), s)):
        path = os.path.join(src, name, "out.jsonl")
        if not os.path.isfile(path):
            continue
        kept = dropped = 0
        out_lines = []
        limits_ids = set()
        for line in open(path):
            o = json.loads(line)
            if o.get("driver") == "sent" and (o.get("obj") or {}).get("method") == "account/rateLimits/read":
                limits_ids.add(o["obj"].get("id"))
            e = o.get("ev")
            if e is not None:
                m = e.get("method")
                if m in DROP:
                    dropped += 1
                    continue
                if m is None and e.get("id") in limits_ids and "result" in e:
                    e["result"] = strip_limits(e["result"])
                r = e.get("result")
                if isinstance(r, dict) and r.get("codexHome"):
                    codex_homes.add(r["codexHome"])
                o["ev"] = strip_plan(strip_git(e))
            if o.get("driver") == "start":
                o.pop("env_keys", None)
            text = clean(json.dumps(o, ensure_ascii=False))
            if EMAIL.search(text):
                sys.exit(f"{name}: 이메일 모양의 글자가 남았다 — 규칙을 고친다: {EMAIL.search(text).group(0)}")
            out_lines.append(text)
            kept += 1
        runs[name] = "\n".join(out_lines) + "\n"
        print(f"{name}: {kept}줄 남김, {dropped}줄 버림")
    # 식별자의 가짜 값은 모든 시험의 기록을 함께 보고 매긴다.
    ids = FixtureIds(runs.values())
    for name, text in runs.items():
        with open(os.path.join(dst, f"{name}.jsonl"), "w") as f:
            f.write(ids.rename(text))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--rewrite":
        rewrite_fixtures(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "--check":
        check_fixtures(sys.argv[2])
    elif len(sys.argv) == 3:
        sanitize_raw(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
