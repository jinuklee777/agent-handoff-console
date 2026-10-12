#!/usr/bin/env python3
"""원본 → 재생 시험 기록. 서명 · 내장 스킬 본문 · 계정 정보는 제거하고, 커넥터 이름은 중립 이름으로, 세션 · 메시지 · 요청 · 도구 호출
식별자는 같은 꼴의 가짜 값으로 바꾸고, 이벤트 순서 · 사용량은 보존한다.

python3 sanitize.py <원본 폴더> <출력 폴더>
python3 sanitize.py --rewrite <저장소 logs 폴더>   # 이미 정리한 기록에 지금의 규칙을 다시 적용 (제자리)
python3 sanitize.py --check <저장소 logs 폴더>

알려진 기록 형식을 정리하며 모든 개인정보를 탐지하지는 않는다.
"""
import argparse
import json
import os
import re
from pathlib import Path

DROP_SYSTEM = {"commands_changed", "hook_started", "hook_response", "thinking_tokens", "status"}
INIT_DROP = {"slash_commands", "terminal_slash_commands", "skills", "memory_paths", "messaging_socket_path"}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
REFERENCE_TITLE = "# Workflow authoring reference"
OMITTED_REFERENCE = "[Built-in skill reference omitted from replay fixture.]"

# claude.ai 커넥터(MCP 서버). 서버 이름은 init 의 `mcp_servers` 에 "claude.ai <이름>" 으로,
# 도구 이름은 `mcp__claude_ai_<이름>__<도구>` 로 온다. 도구 이름(`<서비스>_search` 등)만으로도 서비스가 드러난다.
SERVER_PREFIX = "claude.ai "
NEUTRAL_SERVER = re.compile(r"Connector_[A-Z]")
NEUTRAL_TOOL = re.compile(r"tool_\d{2,}")
CONNECTOR_TOOL = re.compile(r"mcp__claude_ai_(?P<server>[A-Za-z0-9-]+(?:_[A-Za-z0-9-]+)*)__(?P<tool>[A-Za-z0-9_-]+)")
BACKTICKED = re.compile(r"`([A-Za-z0-9_-]+)`")


def strip_private_content(value):
    # 서명은 불투명한 인증 메타데이터다. 해독할 수 없어도 보존하지 않는다.
    if isinstance(value, dict):
        return {key: strip_private_content(item) for key, item in value.items()
                if key not in {"signature", "signature_delta"}}
    if isinstance(value, list):
        return [strip_private_content(item) for item in value]
    if isinstance(value, str) and REFERENCE_TITLE in value:
        return OMITTED_REFERENCE
    return value


def map_strings(value, change):
    """모든 글자(키 포함)에 change 를 적용한 사본."""
    if isinstance(value, dict):
        return {change(key): map_strings(item, change) for key, item in value.items()}
    if isinstance(value, list):
        return [map_strings(item, change) for item in value]
    if isinstance(value, str):
        return change(value)
    return value


def walk_strings(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from walk_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_strings(item)
    elif isinstance(value, str):
        yield value


def server_names(value):
    """`mcp_servers` 목록의 claude.ai 커넥터 이름 ("claude.ai " 뒤)."""
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "mcp_servers" and isinstance(item, list):
                for server in item:
                    name = server.get("name") if isinstance(server, dict) else None
                    if isinstance(name, str) and name.startswith(SERVER_PREFIX):
                        yield name[len(SERVER_PREFIX):]
            else:
                yield from server_names(item)
    elif isinstance(value, list):
        for item in value:
            yield from server_names(item)


def server_slug(name):
    # Claude Code 가 도구 이름에 넣는 서버 이름: 영숫자 · _ · - 밖의 글자는 _ ("Connector A" → "Connector_A").
    return re.sub(r"[^A-Za-z0-9_-]", "_", name)


class ConnectorNames:
    """claude.ai 커넥터의 서버 · 도구 이름 → 중립 이름 (`Connector A`, `mcp__claude_ai_Connector_A__tool_01`).

    번호는 넘겨받은 기록 전체에서 모은 이름의 정렬 순서로 매긴다 — 같은 이름은 어느 파일에서나 같은 중립 이름이 된다.
    이미 중립인 이름은 그대로 두고, 새 이름은 남은 글자 · 다음 번호부터 받는다.
    """

    def __init__(self, records):
        displays, slugs, tools = set(), set(), {}
        for record in records:
            for name in server_names(record):
                displays.add(name)
                slugs.add(server_slug(name))
            for text in walk_strings(record):
                for match in CONNECTOR_TOOL.finditer(text):
                    slugs.add(match["server"])
                    tools.setdefault(match["server"], set()).add(match["tool"])
        used = {slug[-1] for slug in slugs if NEUTRAL_SERVER.fullmatch(slug)}
        free = [letter for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" if letter not in used]
        fresh = sorted(slug for slug in slugs if not NEUTRAL_SERVER.fullmatch(slug))
        if len(fresh) > len(free):
            raise ValueError("커넥터가 너무 많아 Connector A~Z 로 나눌 수 없습니다")
        self.servers = {slug: slug for slug in slugs if NEUTRAL_SERVER.fullmatch(slug)}
        self.servers.update({slug: "Connector_" + letter for slug, letter in zip(fresh, free)})
        self.displays = {name: SERVER_PREFIX + self.servers[server_slug(name)].replace("_", " ")
                         for name in displays if not NEUTRAL_SERVER.fullmatch(server_slug(name))}
        self.tools = {}
        for slug, names in tools.items():
            taken = [int(name[len("tool_"):]) for name in names if NEUTRAL_TOOL.fullmatch(name)]
            fresh_tools = sorted(name for name in names if not NEUTRAL_TOOL.fullmatch(name))
            for number, name in enumerate(fresh_tools, max(taken, default=0) + 1):
                self.tools[(slug, name)] = f"tool_{number:02d}"

    def rename_text(self, text):
        def tool(match):
            slug, name = match["server"], match["tool"]
            neutral = self.tools.get((slug, name), name)
            return f"mcp__claude_ai_{self.servers.get(slug, slug)}__{neutral}"
        text = CONNECTOR_TOOL.sub(tool, text)
        for name in sorted(self.displays, key=len, reverse=True):
            text = text.replace(SERVER_PREFIX + name, self.displays[name])
        for slug in sorted(self.servers, key=len, reverse=True):
            if self.servers[slug] != slug:
                text = re.sub(re.escape("claude_ai_" + slug) + r"(?![A-Za-z0-9-]|_[A-Za-z0-9])",
                              "claude_ai_" + self.servers[slug], text)
        # 글 속에서 커넥터를 말하며 `도구` 로 적은 도구 이름 (실측 t4 의 하위 에이전트 답).
        for slug, neutral in self.servers.items():
            if "claude_ai_" + neutral in text or SERVER_PREFIX + neutral.replace("_", " ") in text:
                names = {name: renamed for (owner, name), renamed in self.tools.items() if owner == slug}
                if names:
                    text = BACKTICKED.sub(lambda m: f"`{names.get(m[1], m[1])}`", text)
        return text

    def apply(self, record):
        return map_strings(record, self.rename_text)


# Claude CLI · Anthropic API 가 매긴 식별자 — 세션(`session_id`) · 이벤트(`uuid`) · 요청 · 메시지(`msg_…`) · API 요청(`req_…`) ·
# 도구 호출(`toolu_…`). 실제 계정의 세션 · 메시지를 가리키므로 같은 꼴의 가짜 값으로 바꾼다.
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
PREFIXED_ID = re.compile(r"\b(?P<prefix>msg|req|toolu)_(?P<body>[0-9A-Za-z]{20,})\b")
FAKE_UUID = re.compile(r"[0-9a-f]{8}-0000-[0-9a-f]000-8000-0{12}")
FAKE_BODY = "01Fixture"


class FixtureIds:
    """식별자 → 같은 꼴의 가짜 값 (UUID 는 `0000002a-0000-4000-8000-000000000000` — 판 글자는 그대로,
    `toolu_01…` 은 `toolu_01Fixture000000000000042` — 길이 그대로).

    번호는 넘겨받은 기록 전체에서 모은 값의 정렬 순서로 매긴다 — 같은 값은 어느 파일에서나 같은 가짜 값이 되고(재생 시험의
    짝짓기가 그대로), 값끼리의 순서도 그대로다. 이미 가짜인 값은 그대로 두고, 새 값은 다음 번호부터 받는다.
    """

    def __init__(self, records):
        uuids, prefixed = set(), set()
        for record in records:
            for text in walk_strings(record):
                uuids.update(UUID.findall(text))
                prefixed.update(match[0] for match in PREFIXED_ID.finditer(text))
        taken = [int(value[:8], 16) for value in uuids if FAKE_UUID.fullmatch(value)]
        fresh = sorted(value for value in uuids if not FAKE_UUID.fullmatch(value))
        self.uuids = {value: f"{number:08x}-0000-{value[14]}000-8000-000000000000"
                      for number, value in enumerate(fresh, max(taken, default=0) + 1)}
        bodies = {value: PREFIXED_ID.fullmatch(value)["body"] for value in prefixed}
        taken = [int(body[len(FAKE_BODY):]) for body in bodies.values() if is_fake_body(body)]
        fresh = sorted(value for value, body in bodies.items() if not is_fake_body(body))
        self.prefixed = {}
        for number, value in enumerate(fresh, max(taken, default=0) + 1):
            prefix, body = value.split("_", 1)
            self.prefixed[value] = f"{prefix}_{FAKE_BODY}{str(number).zfill(len(body) - len(FAKE_BODY))}"

    def rename_text(self, text):
        text = UUID.sub(lambda match: self.uuids.get(match[0], match[0]), text)
        return PREFIXED_ID.sub(lambda match: self.prefixed.get(match[0], match[0]), text)

    def apply(self, record):
        return map_strings(record, self.rename_text)


def is_fake_body(body):
    return body.startswith(FAKE_BODY) and body[len(FAKE_BODY):].isdigit()


def id_leaks(record):
    """가짜가 아닌 식별자의 수 (값 자체는 돌려주지 않는다)."""
    count = 0
    for text in walk_strings(record):
        count += sum(1 for value in UUID.findall(text) if not FAKE_UUID.fullmatch(value))
        count += sum(1 for match in PREFIXED_ID.finditer(text) if not is_fake_body(match["body"]))
    return count


def connector_leaks(record):
    """중립 이름이 아닌 커넥터 서버 · 도구 이름의 수 (값 자체는 돌려주지 않는다)."""
    count = sum(1 for name in server_names(record) if not NEUTRAL_SERVER.fullmatch(server_slug(name)))
    for text in walk_strings(record):
        for match in CONNECTOR_TOOL.finditer(text):
            if not NEUTRAL_SERVER.fullmatch(match["server"]) or not NEUTRAL_TOOL.fullmatch(match["tool"]):
                count += 1
    return count


def sanitize_record(record, connectors=None):
    record = strip_private_content(record)
    event = record.get("ev")
    if isinstance(event, dict):
        kind, subtype = event.get("type"), event.get("subtype")
        if kind == "stream_event" or (kind == "system" and subtype in DROP_SYSTEM):
            return None
        if kind == "control_response":
            inner = event.get("response", {}).get("response")
            if isinstance(inner, dict) and "account" in inner:
                event["response"]["response"] = {"_stripped": "initialize 응답 (계정 · 명령 목록 · 모델 목록) — 저장소에 넣지 않는다"}
        if kind == "system" and subtype == "init":
            for key in INIT_DROP:
                event.pop(key, None)
    if record.get("driver") == "start":
        record.pop("env_keys", None)
    return connectors.apply(record) if connectors else record


def clean_paths(text, source, home):
    paths = {os.path.realpath(source), str(source).rstrip("/")}
    for slug in sorted({p.replace("/", "-") for p in paths}, key=len, reverse=True):
        text = text.replace(slug, "<probe-slug>")
    for path in sorted(paths, key=len, reverse=True):
        text = text.replace(path, "<probe>")
    text = text.replace(home.replace("/", "-"), "-~").replace(home, "~")
    user = os.path.basename(home)
    return re.sub(r"\b" + re.escape(user) + r"\b", "<user>", text) if user else text


def fixture_files(directory):
    files = sorted(Path(directory).glob("t[1-8].jsonl"))
    if len(files) != 8:
        raise ValueError("t1~t8.jsonl 여덟 파일이 모두 필요합니다")
    return files


def check_fixtures(directory):
    for path in fixture_files(directory):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            record = json.loads(line)
            if sanitize_record(record) != record or EMAIL.search(line) or connector_leaks(record) or id_leaks(record):
                # 의심되는 값 자체는 CI 로그에 출력하지 않는다.
                raise ValueError(f"{path.name}:{number}: 제거할 서명 · 스킬 본문 · 계정 정보 · 커넥터 이름 · 실제 식별자가 남았습니다")
    print("Claude 재생 기록 8개: 공개용 정리 검사 통과")


def rewrite_fixtures(directory):
    files = fixture_files(directory)
    records = {path: [json.loads(line) for line in path.read_text().splitlines()] for path in files}
    connectors = ConnectorNames(record for lines in records.values() for record in lines)
    ids = FixtureIds(record for lines in records.values() for record in lines)
    for path, lines in records.items():
        cleaned = [sanitize_record(record, connectors) for record in lines]
        kept = [json.dumps(ids.apply(record), ensure_ascii=False) for record in cleaned if record is not None]
        path.write_text("\n".join(kept) + "\n")
        print(f"{path.stem}: {len(kept)}줄 남김, {len(lines) - len(kept)}줄 버림")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--rewrite", action="store_true")
    parser.add_argument("source")
    parser.add_argument("destination", nargs="?")
    args = parser.parse_args()
    if args.check:
        check_fixtures(args.source)
        return
    if args.rewrite:
        rewrite_fixtures(args.source)
        return
    if not args.destination:
        parser.error("출력 폴더가 필요합니다")
    destination = Path(args.destination)
    destination.mkdir(parents=True, exist_ok=True)
    runs = {}
    for path in sorted(Path(args.source).glob("*/out.jsonl")):
        records = [sanitize_record(json.loads(line)) for line in path.read_text().splitlines()]
        runs[path] = records
    # 커넥터의 중립 이름은 모든 시험의 기록을 함께 보고 매긴다 — 시험마다 같은 이름이 같은 번호가 된다.
    connectors = ConnectorNames(record for records in runs.values() for record in records if record is not None)
    # 식별자의 가짜 값도 모든 시험의 기록을 함께 보고 매긴다 — 재개한 시험이 앞 시험의 세션을 같은 가짜 값으로 가리킨다.
    ids = FixtureIds(record for records in runs.values() for record in records if record is not None)
    for path, records in runs.items():
        lines = []
        for record in records:
            if record is None:
                continue
            text = clean_paths(json.dumps(ids.apply(connectors.apply(record)), ensure_ascii=False), args.source,
                               os.path.expanduser("~"))
            if EMAIL.search(text):
                raise ValueError(f"{path.parent.name}: 이메일 모양의 글자가 남았습니다")
            lines.append(text)
        (destination / (path.parent.name + ".jsonl")).write_text("\n".join(lines) + "\n")
        print(f"{path.parent.name}: {len(lines)}줄 남김, {len(records) - len(lines)}줄 버림")


if __name__ == "__main__":
    main()
