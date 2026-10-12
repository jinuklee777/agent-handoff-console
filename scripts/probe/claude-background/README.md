# Claude 서브에이전트 · 백그라운드 작업 실측

앱이 Claude 의 서브에이전트 · 백그라운드 에이전트 · Workflow(ultracode) · 백그라운드 셸을 어떻게 다뤄야 하는지 정하려고, **앱과 같은 인수로 `claude -p` 를 띄워** 출력 전체를 기록한 도구와 그 기록이다. 앱 코드와는 독립이다.

- 결과 요약: [CLI 프로토콜](../../../docs/CLI프로토콜.md)의 "서브에이전트 · 백그라운드 작업" 절
- 이 결과로 만든 앱의 판정: `AgentHandoffConsole/Agents/ClaudeTurnTracker.swift` — 이 기록을 그대로 넣어 보는 재생 시험은 `scripts/inttest/ClaudeReplayTests.swift` (`inttest offline` 에 들어 있다)

## 파일

| 파일 | 하는 일 |
|---|---|
| `driver.py` | `claude -p` 하나를 앱과 같은 인수(`--input-format/--output-format stream-json --verbose --include-partial-messages --permission-mode manual --permission-prompt-tool stdio`)로 띄운다. 초기화 · 사용자 메시지 · 승인 응답 형식도 `ClaudeAdapter` 와 같다. **다른 점: 첫 `result` 에서 끄지 않고** 이후 출력을 더 기록한다. `--action` 으로 대기 중 동작 하나(stop_task · interrupt · close_stdin · send_message)를 넣는다 |
| `run.sh` | 시험 여덟 개를 네 개씩 동시에 돌린다 (`set1` · `set2` · `all`). **실제 CLI · 구독 사용량을 쓴다** |
| `analyze.py` | 기록 → 사람이 읽는 타임라인 (`stream_event` 는 개수만) |
| `sanitize.py` | 원본 → 저장소용. 계정 정보가 든 `initialize` 응답 본문 · 환경마다 다른 이벤트 · 개인 경로 · 모든 thinking 서명 · 내장 스킬 참조 본문을 지우고, claude.ai 커넥터의 서버 · 도구 이름을 중립 이름(`claude.ai Connector A` · `mcp__claude_ai_Connector_A__tool_01`)으로 바꾼다 — 도구 이름만으로도 어떤 서비스인지 드러난다. 번호는 모든 기록의 이름을 함께 정렬해 매기므로 같은 도구는 어느 기록에서나 같은 이름이다. 세션 · 이벤트(UUID) · 메시지(`msg_…`) · 요청(`req_…`) · 도구 호출(`toolu_…`) 식별자는 같은 꼴의 가짜 값(`00000001-0000-4000-8000-000000000000` · `toolu_01Fixture…`)으로 바꾼다 (`FixtureIds` — 같은 방식으로 번호를 매겨 재생 시험의 짝짓기가 그대로다) |
| `test_sanitize.py` | 중첩 서명 · 내장 스킬 본문 제거, 커넥터 이름 · 식별자의 중립화 · `--check` 의 거절, 이벤트 시각 · 사용량 보존을 검증한다 |
| `logs/t1~t8.jsonl` | 2026-09-22 기록 (claude 2.1.270, `claude-sonnet-5`), sanitize 를 거친 것. 앞으로의 오프라인 재생 시험 자료 |

## 시험

| | 요청 | 확인한 것 |
|---|---|---|
| t1 | 일반 Agent 두 개 병렬 (Explore · general-purpose) | 서브에이전트 안의 호출이 `parent_tool_use_id` 로 온다. 마지막 답은 따로 안 온다. `task_*` 이벤트. `modelUsage` 에 Haiku 가 낀다 |
| t2 | 백그라운드 Agent 하나 | `result` 가 먼저 오고, 끝나면 CLI 가 스스로 후속 턴 (`origin.kind = task-notification`) |
| t3 | `ultracode …` | `-p` 에서도 Workflow 가 뜬다 (승인 요청 있음). 워크플로 안 에이전트는 `task_progress` 만 |
| t4 | 읽기 전용(`--disallowedTools Write Edit NotebookEdit Bash`) + 파일 쓰기를 시키는 Agent | 서브에이전트에도 쓰기 도구가 없다. probe.txt 안 생김 |
| t5 | 대기 중 `stop_task` | 그 작업만 멈춤. 서브에이전트 소유 작업이면 그 서브에이전트가 다시 깬다 |
| t6 | 대기 중 `interrupt` | 백그라운드 작업 전부 멈춤. `result` 없음 |
| t7 | 대기 중 stdin 닫기 | 진행 중 후속 턴을 마치고, 남은 작업을 멈추고 스스로 끝남 |
| t8 | 대기 중 새 사용자 메시지 | 바로 답함. 작업은 계속, 끝나면 후속 턴 |

t5~t8 은 서브에이전트에게 `sleep 40` 을 시켰는데, CLI 가 단독 `sleep` 을 막아 서브에이전트가 백그라운드 셸로 다시 띄웠다. 그 덕에 "후속 `result` 뒤에도 작업이 남는" 경우와 서브에이전트 소유 작업이 함께 관찰됐다.

## 다시 돌리기

```bash
./run.sh all                                   # 원본은 $TMPDIR/claude-background-probe
python3 analyze.py "$TMPDIR/claude-background-probe/t2/out.jsonl"
python3 sanitize.py "$TMPDIR/claude-background-probe" logs   # 저장소에 넣을 때만
python3 sanitize.py --rewrite logs                            # 정리 규칙을 바꾼 뒤 저장소의 기록에 다시 적용 (제자리)
```

- **도구 셸에서 돌릴 때 주의:** Claude Code 같은 에이전트 안의 셸에는 `CLAUDE*` · `ANTHROPIC_BASE_URL` 변수가 있어 그대로 띄우면 앱과 조건이 달라진다. `driver.py` 는 PATH · HOME 등 몇 가지만 넘기고 나머지는 버린다.
- 모델은 `MODEL=…` 로 바꾼다. 재는 것은 이벤트의 모양이라 Sonnet 5 로 충분했다.
- 원본(`out.jsonl`)에는 계정 이메일 · 조직 이름이 들어 있다. 저장소에는 `sanitize.py` 를 거친 것만 넣는다.

## 공개용 검사

서명 안에도 계정 식별자가 들어갈 수 있으므로 `signature`는 해독 여부와 관계없이 제거한다.
내장 스킬의 참조 본문은 짧은 대체 글로 바꾸며, 재생 시험에 필요한 이벤트 종류 · 순서 · 시각 · 사용량은 보존한다.
`--check` 는 중립 이름이 아닌 커넥터 서버 · 도구 이름이 남아 있어도 거절한다.
다음 검사는 CI에서도 실행한다. 임의의 개인정보를 모두 찾는 검사는 아니므로 새 실측 기록은 별도로 검토한다.

```bash
python3 -m unittest discover -s scripts/probe/claude-background -p 'test_*.py'
python3 scripts/probe/claude-background/sanitize.py --check scripts/probe/claude-background/logs
```
