# Codex 하위 에이전트 · 백그라운드 작업 실측

[Claude 쪽 실측](../claude-background/README.md)과 같은 질문을 Codex 에 던진 도구와 기록이다: Codex 가 스스로 하위 에이전트(`multi_agent`)를 띄우거나 백그라운드 터미널(`unified_exec`)을 남기면 이 앱에서는 어떻게 되는가. **앱과 같은 순서 · 같은 기본값으로 `codex app-server --stdio` 를 띄워** 출력 전체를 기록한다. 앱 코드와는 독립이다.

- 결과 요약: [CLI 프로토콜](../../../docs/CLI프로토콜.md)의 Codex "하위 에이전트 · 백그라운드 작업" 절
- 이 결과로 만든 앱의 판정: `AgentHandoffConsole/Agents/CodexTurnTracker.swift` — 이 기록을 그대로 넣어 보는 재생 시험은 `scripts/inttest/CodexReplayTests.swift` (`inttest offline` 에 들어 있다)

## 파일

| 파일 | 하는 일 |
|---|---|
| `driver.py` | `codex app-server --stdio` 하나를 앱(`CodexAdapter`)과 같은 순서로 띄운다: `initialize` → `thread/start{cwd, sandbox: workspace-write, approvalPolicy: on-request, model}` (또는 `--resume` 이면 `thread/resume{…, excludeTurns}`) → `turn/start{input, model, effort}`. 읽기 전용이면 앱처럼 `read-only` · `never` · `sandboxPolicy: readOnly`. **다른 점: 메인 스레드의 `turn/completed` 에서 끄지 않고** 조용해질 때까지 더 기록한 뒤, 불러온 스레드 목록 · 스레드마다 `thread/read` 를 남긴다. `--action` 으로 동작 하나(interrupt_main · interrupt_app_like · interrupt_child · close_stdin · app_shutdown · send_message · inject_shutdown)를 넣고(`--action-when children_done` 이면 하위 턴이 모두 끝난 뒤), `--watch-proc` · `--watch-file` 로 끈 뒤 남은 프로세스 · 파일을 본다 |
| `run.sh` | 시험 열일곱 개를 `set1` ~ `set4` 로 나눠 동시에 돌린다. **실제 CLI · 구독 사용량을 쓴다.** 계정은 `CODEX_HOME_PROBE` (기본 `~/.codex`) |
| `analyze.py` | 기록 → 사람이 읽는 타임라인. 스레드를 M(메인) · A · B … 로 줄이고 글자 조각 알림은 개수만 |
| `app_view.py` | 기록을 **고치기 전의 `CodexAdapter` 가 읽었다면** 언제 실행을 끝내고, 무엇을 응답으로 보이고, 사용량을 얼마로 적었을지 흉내 낸다 (그때의 앱 코드 판독 기준 — 알림을 스레드로 가르지 않던 규칙). 지금의 규칙(`CodexTurnTracker`)은 흉내 내지 않는다 — 현행 판정은 같은 기록을 실제 소스로 재생하는 `scripts/inttest/CodexReplayTests.swift`(`inttest offline`)가 확인한다 |
| `sanitize.py` | 원본 → 저장소용. 계정 ID · 한도 초기화 쿠폰 · 호스트 이름 · 설치 ID · 개인 경로를 지우고, 요금제 이름(`planType`)은 `<plan>` 으로, 스레드 · 턴 · 응답 항목 · 함수 호출 식별자는 같은 꼴의 가짜 값(`00000001-0000-7000-8000-000000000000` · `msg_000…01` · `call_Fixture…`)으로 바꾼다 (`FixtureIds` — 번호는 모든 기록의 값을 함께 정렬해 매기므로 같은 스레드는 어느 기록에서나 같은 값이다). `--rewrite logs` 는 저장소의 기록에 다시 적용하고, `--check logs` 는 이메일 · 실제 식별자가 남았으면 실패한다 |
| `logs/c1~c17.jsonl` · `c15r` · `c17r` | 2026-09-23 기록 (codex-cli 0.154.0, `gpt-5.6-terra` low — c3 만 ultra, 앱에 등록된 Codex 계정 하나), sanitize 를 거친 것. `r` 은 앞 시험의 스레드를 새 프로세스에서 재개한 다음 턴. 오프라인 재생 시험 `scripts/inttest/CodexReplayTests.swift` 의 자료 — 지우거나 옮기면 그 시험이 실패한다 (`ProbeLogs`) |

## 시험

| | 요청 · 동작 | 확인한 것 |
|---|---|---|
| c1 | 하위 에이전트 둘을 병렬로 띄우고 기다리기 | 하위 스레드의 `turn/started` · `item/*` · 글자 조각 · `tokenUsage` · `turn/completed` 가 **같은 연결로, 하위 스레드 ID 를 달고** 온다. `thread/started` 는 오지 않는다. 메인에는 `subAgentActivity` · `collabAgentToolCall(wait)` 항목 |
| c2 | 하위 에이전트 하나를 띄우고 기다리지 않기 | 메인 `turn/completed` 가 먼저 온다. 하위는 계속 돌고, 끝나면 메인 스레드에 `subAgentActivity completed` 항목만 — **후속 턴이 열리지 않는다** (Claude 와 다름). 하위의 답은 메인 대기열로 간다 (c14~c16) |
| c3 | ultra 강도 + "각각 다른 에이전트가" | 같은 도구로 셋을 띄운다. 하위도 ultra 를 물려받는다 |
| c4 | 읽기 전용 턴 + 파일을 쓰라는 하위 에이전트 | 하위에도 읽기 전용이 이어진다 (`apply_patch` 실패, probe.txt 없음) |
| c5 | 백그라운드 터미널(짧은 yield 로 `sleep 45 && …`) 남기고 턴 끝내기 | 턴이 끝나도 명령은 app-server 의 자식으로 돌고, 끝나면 턴 밖에서 `item/completed` 가 온다. 후속 턴 없음 |
| c6 | 하위를 기다리는 중 메인 턴 `turn/interrupt` | 메인만 `interrupted`. **하위는 끝까지 돈다** |
| c7 | 안 기다린 하위가 도는 중 stdin 닫기 | app-server 가 곧바로 끝나고 하위의 명령도 죽는다 |
| c8 | 안 기다린 하위가 도는 중 새 `turn/start` | 바로 답한다. 하위는 계속, 끝나도 후속 턴 없음 |
| c9 | 백그라운드 터미널 + 앱처럼 끄기(stdin 닫기 → SIGTERM) | 1초 안에 끝나고 남는 프로세스 없음, 명령의 결과 파일도 없음 |
| c10 | 안 기다린 하위의 턴에 `turn/interrupt{하위 스레드, 하위 턴}` | 그 턴은 곧바로 `interrupted`. **하지만 그 턴이 돌리던 셸 명령은 끝까지 돈다** |
| c11 | 안 기다린 하위 + 앱처럼 끄기 | 하위와 그 명령이 함께 죽는다. 남는 프로세스 없음 |
| c12 | 하위를 기다리는 중 **앱처럼** 중단 (메인 스레드 ID + 마지막 `turn/started` 의 턴 ID = 하위 턴) | `-32600 expected active turn id … but found …` 로 거절 |
| c13 | c11 의 메인 스레드를 새 프로세스에서 재개하고 하위 상태를 묻기 (앱의 다음 턴) | 하위 스레드는 다시 올라오지 않고 모델의 `wait` 는 시간 초과만 받는다. 재개 직후 **이전 턴의 `tokenUsage` 가 한 번 다시 온다** |
| c14 | 기다리지 않은 하위(무작위 8자리를 만든다)가 끝나고 5초 뒤, 같은 프로세스에서 "하위가 보고한 값은?" (도구 금지) | **UNKNOWN.** 하위의 답은 턴을 일으키지 않는 메시지(`trigger_turn: false`)로 메인 대기열에 들어가, 이 턴이 **끝날 때** 기록에 붙는다 (rollout 에서 확인) |
| c15 · c15r | 하위가 끝나고 조용해지면 끔 → 새 프로세스에서 재개해 같은 질문 | **UNKNOWN.** 대기열의 메시지는 기록되지 않고 사라진다 |
| c16 | c14 와 같되 아무 메시지("ok") 한 번 뒤에 질문 | 값을 맞힌다 — 결과는 **다다음 턴**부터 보인다 |
| c17 · c17r | 하위가 끝나면 그 답을 `thread/inject_items`(developer 메시지)로 메인 기록에 넣고 끔 → 재개해 질문 | 값을 맞힌다 — 넣는 순간에는 턴도 모델 호출도 없고, 재개한 **바로 다음 턴**에서 보인다 |

하위 에이전트의 `sleep` 은 시험마다 초를 달리해(41~48) 끈 뒤 `ps` 로 남은 프로세스를 찾았다. c14~c17 의 "메인이 아는가"는 메인의 답과 함께 Codex 가 남기는 메인 스레드의 rollout(`<CODEX_HOME>/sessions/…`, `thread/read` 의 `path`)에서 하위의 값이 언제 · 어떤 항목으로 붙었는지로 확인했다 (rollout 은 저장소에 넣지 않았다).

## 다시 돌리기

```bash
CODEX_HOME_PROBE=~/.codex-accounts/account2 ./run.sh all   # 원본은 $TMPDIR/codex-background-probe
python3 analyze.py "$TMPDIR/codex-background-probe/c1/out.jsonl"
python3 app_view.py logs/c1.jsonl logs/c3.jsonl            # 고치기 전의 어댑터였다면 — 지금의 판정은 inttest offline 의 CodexReplayTests
python3 sanitize.py "$TMPDIR/codex-background-probe" logs  # 저장소에 넣을 때만
python3 sanitize.py --check logs                             # 이메일 · 실제 식별자가 남지 않았는지 (CI 도 돌린다)
```

- **`run.sh` 가 도는 동안 `run.sh` 를 고치지 않는다.** bash 는 스크립트를 조금씩 읽어서, 도중에 고치면 엉뚱한 위치부터 읽는다.
- 도구 셸의 `CLAUDE*` · `CODEX_*` 변수는 넘기지 않는다. `driver.py` 는 PATH(로그인 셸) · HOME 등 몇 가지와 `CODEX_HOME` 만 넘긴다.
- 모델 · 강도는 `MODEL=…` · `EFFORT=…`. 재는 것은 알림의 모양이라 terra low 로 충분했다.
- 원본(`out.jsonl`)에는 계정 ID · 요금제 · 호스트 이름이 들어 있다. 저장소에는 `sanitize.py` 를 거친 것만 넣는다.
- 하위 에이전트 기능은 CLI 기능 `multi_agent`(안정 · 켜짐), 백그라운드 터미널은 `unified_exec`(안정 · 켜짐)이다 — `codex features list` 로 확인.
