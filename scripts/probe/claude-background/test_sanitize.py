import base64
import contextlib
import copy
import io
import json
import tempfile
import unittest
from pathlib import Path

import sanitize


class SanitizerTests(unittest.TestCase):
    def test_opaque_signature_removed_without_decoding(self):
        original = {"ev": {"message": {"content": [
            {"type": "thinking", "thinking": "fixture reasoning",
             "signature": base64.b64encode(b"private organisation metadata").decode()},
            {"type": "text", "text": "result"}]}}}
        saved = copy.deepcopy(original)
        result = sanitize.sanitize_record(original)
        self.assertNotIn("signature", result["ev"]["message"]["content"][0])
        self.assertEqual(result["ev"]["message"]["content"][1], {"type": "text", "text": "result"})
        self.assertEqual(original, saved)

    def test_builtin_reference_replaced_but_event_preserved(self):
        record = {"t": 12.5, "ev": {"type": "user", "message": {"content": [
            {"type": "text", "text": sanitize.REFERENCE_TITLE + "\nfixture body"}]}}}
        result = sanitize.sanitize_record(record)
        self.assertEqual(result["t"], 12.5)
        self.assertEqual(result["ev"]["type"], "user")
        self.assertEqual(result["ev"]["message"]["content"][0]["text"], sanitize.OMITTED_REFERENCE)

    def test_stream_signature_fragment_is_dropped(self):
        record = {"ev": {"type": "stream_event", "event": {"delta": {
            "type": "signature_delta", "signature": "fragment"}}}}
        self.assertIsNone(sanitize.sanitize_record(record))

    def test_initialize_account_and_skills_removed(self):
        record = {"ev": {"type": "control_response", "response": {"response": {
            "account": {"email": "fixture@example.invalid"}, "commands": ["private"]}}}}
        self.assertIn("_stripped", sanitize.sanitize_record(record)["ev"]["response"]["response"])
        record = {"ev": {"type": "system", "subtype": "init", "skills": ["private"], "session_id": "fixture"}}
        self.assertEqual(sanitize.sanitize_record(record)["ev"],
                         {"type": "system", "subtype": "init", "session_id": "fixture"})

    def test_replay_usage_timing_unchanged_and_idempotent(self):
        record = {"t": 19.81, "ev": {"type": "result", "result": "fixture result",
                                    "usage": {"input_tokens": 100, "output_tokens": 7}, "total_cost_usd": 0.2}}
        self.assertEqual(sanitize.sanitize_record(record), record)
        self.assertEqual(sanitize.sanitize_record(sanitize.sanitize_record(record)), record)


class ConnectorNameTests(unittest.TestCase):
    """커넥터의 서버 · 도구 이름은 서비스를 드러낸다 — 중립 이름으로 바꾸고, 남으면 --check 가 거절한다."""

    @staticmethod
    def init(tools, servers):
        return {"t": 1.0, "ev": {"type": "system", "subtype": "init", "session_id": "fixture",
                                 "tools": ["Bash", "Read"] + tools,
                                 "mcp_servers": [{"name": "claude.ai " + name, "status": "connected"} for name in servers]}}

    def fixture(self):
        first = self.init(["mcp__claude_ai_Fixture_Docs__search", "mcp__claude_ai_Fixture_Docs__fetch",
                           "mcp__claude_ai_Connector_A__tool_01"], ["Fixture Docs", "Connector A"])
        later = {"t": 2.0, "ev": {"type": "user", "message": {"content": [{"type": "tool_result", "content": [
            {"type": "tool_reference", "tool_name": "mcp__claude_ai_Fixture_Docs__search"},
            {"type": "tool_reference", "tool_name": "Monitor"}]}]}}}
        answer = {"t": 3.0, "ev": {"type": "result", "result":
                  "The claude_ai_Fixture_Docs tools (`fetch`/`search`) are remote; `Read` is local."}}
        return [first, later, answer]

    def test_tool_and_server_names_become_neutral_and_stable(self):
        records = self.fixture()
        saved = copy.deepcopy(records)
        connectors = sanitize.ConnectorNames(records)
        first, later, answer = (sanitize.sanitize_record(record, connectors) for record in records)
        self.assertEqual(records, saved)
        self.assertEqual(first["ev"]["tools"], ["Bash", "Read", "mcp__claude_ai_Connector_B__tool_02",
                                                "mcp__claude_ai_Connector_B__tool_01", "mcp__claude_ai_Connector_A__tool_01"])
        self.assertEqual([server["name"] for server in first["ev"]["mcp_servers"]],
                         ["claude.ai Connector B", "claude.ai Connector A"])
        # 다른 줄의 같은 도구는 같은 중립 이름, 커넥터가 아닌 도구는 그대로.
        self.assertEqual([item["tool_name"] for item in later["ev"]["message"]["content"][0]["content"]],
                         ["mcp__claude_ai_Connector_B__tool_02", "Monitor"])
        self.assertEqual(answer["ev"]["result"],
                         "The claude_ai_Connector_B tools (`tool_01`/`tool_02`) are remote; `Read` is local.")
        self.assertEqual(sum(sanitize.connector_leaks(record) for record in (first, later, answer)), 0)
        # 다시 돌려도 바뀌지 않는다.
        again = sanitize.ConnectorNames([first, later, answer])
        self.assertEqual([sanitize.sanitize_record(record, again) for record in (first, later, answer)],
                         [first, later, answer])

    def test_new_tools_of_a_neutral_server_continue_numbering(self):
        record = self.init(["mcp__claude_ai_Connector_A__tool_01", "mcp__claude_ai_Connector_A__fixture_lookup"],
                           ["Connector A"])
        renamed = sanitize.sanitize_record(record, sanitize.ConnectorNames([record]))
        self.assertEqual(renamed["ev"]["tools"][-2:],
                         ["mcp__claude_ai_Connector_A__tool_01", "mcp__claude_ai_Connector_A__tool_02"])

    def test_leaks_counted_without_connector_table(self):
        self.assertGreater(sanitize.connector_leaks(self.init(["mcp__claude_ai_Connector_B__fixture_search"],
                                                              ["Connector B"])), 0)
        self.assertGreater(sanitize.connector_leaks(self.init([], ["Fixture Docs"])), 0)
        self.assertEqual(sanitize.connector_leaks(self.init(["mcp__claude_ai_Connector_B__tool_07"],
                                                            ["Connector B"])), 0)
        # 커넥터가 없는 기록은 아무것도 바꾸지 않는다.
        plain = {"t": 1.0, "ev": {"type": "result", "result": "mcp tools: none"}}
        self.assertEqual(sanitize.sanitize_record(plain, sanitize.ConnectorNames([plain])), plain)

    def test_check_rejects_service_tool_names(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            records = [self.init(["mcp__claude_ai_Connector_B__tool_01"], ["Connector B"])]
            for number in range(1, 9):
                Path(directory, f"t{number}.jsonl").write_text(
                    "\n".join(json.dumps(record, ensure_ascii=False) for record in records) + "\n")
            sanitize.check_fixtures(directory)
            Path(directory, "t3.jsonl").write_text(json.dumps(self.fixture()[0], ensure_ascii=False) + "\n")
            with self.assertRaises(ValueError):
                sanitize.check_fixtures(directory)
            sanitize.rewrite_fixtures(directory)
            sanitize.check_fixtures(directory)


class FixtureIdTests(unittest.TestCase):
    """세션 · 이벤트 · 메시지 · 요청 · 도구 호출 식별자는 실제 계정의 것을 가리킨다 — 같은 꼴의 가짜 값으로 바꾸고, 남으면 --check 가 거절한다."""

    SESSION = "6f1e2d3c-4b5a-4968-8776-5544332211aa"
    OTHER = "0a1b2c3d-4e5f-4a6b-9c8d-7e6f5a4b3c2d"

    def fixture(self):
        start = {"t": 1.0, "driver": "start", "args": ["--resume", self.SESSION]}
        init = {"t": 1.1, "ev": {"type": "system", "subtype": "init", "session_id": self.SESSION, "uuid": self.OTHER}}
        call = {"t": 2.0, "ev": {"type": "assistant", "session_id": self.SESSION, "message": {
            "id": "msg_011CfFixtureAbcdefghijkLm", "content": [
                {"type": "tool_use", "id": "toolu_01FixtureAbcdefghijklmnp", "name": "Bash"}]},
            "request_id": "req_011CfFixtureAbcdefghijkLm"}}
        result = {"t": 3.0, "ev": {"type": "user", "parent_tool_use_id": "toolu_01FixtureAbcdefghijklmnp",
                                   "message": {"content": [{"type": "text", "text": f"session {self.SESSION} done"}]}}}
        return [start, init, call, result]

    def test_ids_become_fake_same_shape_and_stable(self):
        records = self.fixture()
        saved = copy.deepcopy(records)
        ids = sanitize.FixtureIds(records)
        start, init, call, result = (ids.apply(record) for record in records)
        self.assertEqual(records, saved)
        session = init["ev"]["session_id"]
        self.assertRegex(session, sanitize.FAKE_UUID)
        self.assertEqual(session[14], "4")
        # 같은 값은 어느 줄 · 어느 자리(인수 · 글 속)에서나 같은 가짜 값.
        self.assertEqual(start["args"][1], session)
        self.assertEqual(call["ev"]["session_id"], session)
        self.assertIn(f"session {session} done", result["ev"]["message"]["content"][0]["text"])
        tool = call["ev"]["message"]["content"][0]["id"]
        self.assertEqual(result["ev"]["parent_tool_use_id"], tool)
        self.assertEqual(len(tool), len("toolu_01FixtureAbcdefghijklmnp"))
        self.assertTrue(tool.startswith("toolu_01Fixture") and tool[len("toolu_01Fixture"):].isdigit())
        self.assertTrue(call["ev"]["message"]["id"].startswith("msg_01Fixture"))
        self.assertTrue(call["ev"]["request_id"].startswith("req_01Fixture"))
        # 값끼리의 순서는 그대로 (OTHER < SESSION).
        self.assertLess(init["ev"]["uuid"], session)
        self.assertEqual(sum(sanitize.id_leaks(record) for record in (start, init, call, result)), 0)
        self.assertGreater(sum(sanitize.id_leaks(record) for record in records), 0)
        # 다시 돌려도 바뀌지 않고, 새 값은 다음 번호부터.
        again = sanitize.FixtureIds([start, init, call, result])
        self.assertEqual([again.apply(record) for record in (start, init, call, result)], [start, init, call, result])
        fresh = {"t": 4.0, "ev": {"type": "result", "session_id": "ffffffff-ffff-4fff-bfff-ffffffffffff"}}
        renamed = sanitize.FixtureIds([start, init, call, result, fresh]).apply(fresh)["ev"]["session_id"]
        self.assertRegex(renamed, sanitize.FAKE_UUID)
        self.assertNotIn(renamed, (session, init["ev"]["uuid"]))

    def test_check_rejects_real_ids(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            records = self.fixture()
            for number in range(1, 9):
                Path(directory, f"t{number}.jsonl").write_text(
                    "\n".join(json.dumps(record, ensure_ascii=False) for record in records) + "\n")
            with self.assertRaises(ValueError):
                sanitize.check_fixtures(directory)
            sanitize.rewrite_fixtures(directory)
            sanitize.check_fixtures(directory)
            first = Path(directory, "t1.jsonl").read_text()
            self.assertEqual(Path(directory, "t8.jsonl").read_text(), first)
            self.assertNotIn(self.SESSION, first)


if __name__ == "__main__":
    unittest.main()
