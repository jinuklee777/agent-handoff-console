# CLI 프로토콜 메모

검증 버전: Claude Code **2.1.266**(기준선) · **2.1.269**(2026-09-12), Codex CLI **0.153.4** (2026-09-09),
Antigravity CLI **1.2.1** · **1.2.2** (2026-09-12 기록은 두 버전에 걸쳐 있다 — 이 문서의 헤더가 그날 1.2.1 에서 1.2.2 로 바뀌었다),
모델 · 강도 · `/boost` 조합은 **1.2.2** 로 2026-09-14 다시 실측.
그 뒤의 실측은 절마다 날짜와 버전을 적었다 — Claude Code 2.1.270 · 2.1.292, Codex CLI 0.154.0 · 0.160.1, Antigravity CLI 1.3.2 (흐르는 글, 2026-10-09).
2026-10-10: 실제 CLI 시험(`inttest env stream approval interrupt handoff antigravity`, Codex 는 gpt-5.6-luna low)이 Claude Code 2.1.295 · Codex CLI 0.162.0 · Antigravity CLI 1.3.3 에서도 통과했다 — 어댑터가 기대는 형태가 그 버전에서도 그대로였다는 뜻이고, 절마다 다시 잰 것은 아니다.
이 문서는 어댑터가 의존하는 실제 입출력 형태를 기록한다. 버전이 바뀌면 여기부터 확인한다.

---

## Antigravity CLI(`agy`) — Gemini 보조 요약과 작업 에이전트

같은 CLI 를 두 가지로 쓴다. **인계 요약 보조**(구조화 출력, 아래)와 **작업 에이전트**(파일 편집·명령 실행).
요약 보조는 빈 임시 폴더에서 슬래시 확장을 끄고 돌리고, 작업 에이전트는 프로젝트 폴더를 열고 자동 승인으로 돌린다.
2026-09-12 이 Mac에서 `agy models`와 아래 호출들을 실제 확인했다.

```
agy --input-format stream-json
    --output-format stream-json
    --json-schema <인계 요약 스키마>
    --model <agy models에서 조회한 slug>
    --sandbox
    --disable-slash-commands
    --print-timeout 2m
stdin (한 줄):  {"event":"user","message":{"content":"<마스킹한 기록>"}}
```

- 검증된 설치 경로: `~/.local/bin/agy`, 버전 `1.2.2`.
- 요약 기본 모델은 조회한 목록에서 **가장 최신 flash 제품군의 high**를 고른다 (이름은 코드에 고정하지 않는다).
  실측 비교에서 `high`가 `low`보다 근거를 대화에 제대로 달아 검증을 통과하는 다음 행동을 남겼다.
- 프로젝트 밖의 빈 임시 폴더에서 실행하고 종료 후 지운다. 프로젝트 경로는 작업 폴더로 주지 않는다.
- `--mode plan`과 `--disable-slash-commands`를 함께 주면 plan이 효력이 없다는 경고가 나와 `--mode`는 쓰지 않는다.
- JSON 오류, 비정상 status, 시간 초과는 규칙 초안으로 대체하며 자동 인계는 품질 게이트에서 멈춘다.

### 입력 — 인수가 아니라 stdin

기록을 `-p <본문>` 인수로 넘기면 `ps` 로 같은 Mac의 다른 프로세스에 보인다. 그래서 stdin 으로 보낸다.

| 실측 | 결과 |
|---|---|
| `-p` 값 | 문자열 값이 필수. 값 없이 끝에 두면 `flag needs an argument: -p` |
| `-p -` | stdin 이 아니라 `-` 글자 자체를 프롬프트로 받는다 |
| `-p ''` | `empty prompt` 오류 (`status: ERROR`) |
| `--input-format text` + stdin | stdin 을 읽지 않는다 |
| `--input-format stream-json` | stdin 한 줄 = 한 턴. 각 줄에 `event` 필드가 필수(`missing the "event" field`). 형식은 `{"event":"user","message":{"content":"…"}}`. `--output-format stream-json` 과 함께 써야 한다 |

### 출력 — stream-json

```
{"event":"init","conversation_id":"…","init":{"model":"…","tools":[…],"permission_mode":"request-review"}}
{"event":"step_update","step_update":{"step_index":0,"state":"DONE","step_type":"user_input"}}
{"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"…"}}   ← 1.3.2: 조각마다 한 줄
{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"…","usage":{…}}}
{"event":"result","result":{"status":"SUCCESS","response":"…","structured_output":{…},"usage":{…},"denied_actions":[…]}}
```

- 마지막 `event == "result"` 줄의 `result` 가 `--output-format json` 의 단일 객체와 같은 모양이다.
- 헤드리스는 셸 명령 권한을 묻지 못해 자동 거절한다. 거절이 있으면 `result.denied_actions` 에 남고,
  stderr 에 `no output produced — a tool required the "command" permission` 이 찍힌다.
  **이때 `status` 는 `SUCCESS` 인데 `structured_output` 이 없다** → 앱은 실패로 보고 규칙 초안으로 대체한다.

### 긴 입력은 약 191.5KB 에서 잘린다

같은 합성 기록을 크기만 바꿔 보냈다.

| 사용자 메시지 | 입력 토큰 | 결과 |
|---|---|---|
| 11만 자 (한글 위주, 약 25만 바이트) | 72,161 | 끝부분을 못 봄 → 원문 파일을 `tail` 하려다 거절, 구조화 결과 없음 |
| 21만 자 (약 48만 바이트) | 72,155 | 위와 동일 (입력 토큰이 늘지 않음) |
| 17.7만 자 (영문 위주, 248,811 바이트) | 84,445 | 모델이 본 마지막 줄 L1389, 이어서 `<truncated 57231 bytes>` 표시 |
| 앱 입력 14.9만 바이트 (한글 위주) | 68,335 | 맨 끝 사용자 지시까지 읽음 (13초) |

- 앞부분 약 **191,580 바이트**만 모델에 보이고 나머지는 `<truncated N bytes>` 로 바뀐다. 글자 수가 아니라 바이트 기준이다.
- 시스템 프롬프트는 약 13.8k 토큰(짧은 프롬프트의 입력 토큰 13,837).
- 앱은 입력을 **150,000 바이트**로 제한하고, 넘치면 오래된 이벤트부터 통째로 뺀다 (최신 이벤트·git 사실 유지).
  `./build/inttest/inttest geminilarge` 가 이 기준을 다시 확인한다.

### 모델과 추론 강도 — 둘 중 하나만, 제품군이면 강도는 필수

```
agy --model gemini-3.8-flash --effort low|medium|high     # 제품군 + 강도
agy --model gemini-3.8-flash-high                          # 강도가 포함된 슬러그
agy --model claude-sonnet-4-6                              # 강도 변형이 없는 모델은 모델만
```

- 두 방식을 섞으면 거부한다: `--model gemini-3.8-flash-low --effort high`
  → `invalid model selection … conflicts with --effort=high`
- 제품군만 주고 강도를 빼도 거부한다 (1.2.1 기록, 1.2.2 에서 2026-09-14 다시 확인 — 아래 표): `--model gemini-3.8-flash`
  → `requires --effort (available: low, medium, high)`. agy 는 **제품군에 쓸 기본 강도를 주지 않는다** (실측한 제품군은 3.8 Flash 하나,
  오류가 모델 해석 단계의 일반 규칙으로 나와 앱은 강도 변형이 있는 다른 제품군도 같게 본다).
- `agy models` 는 `<슬러그>\t<표시 이름>` 형식이다 (`gemini-3.8-flash-high\tGemini 3.8 Flash (High)`).

#### 2026-09-14 실측 (agy 1.2.2, `~/.local/bin/agy`, 빈 임시 폴더, `-p` 텍스트 출력)

| 명령 | 결과 |
|---|---|
| `agy --model gemini-3.8-flash -p "hi"` | **거부** — exit 1, 5초. stderr `error: invalid model selection (--model "gemini-3.8-flash" --effort ""): --model gemini-3.8-flash requires --effort (available: low, medium, high)`. 모델 호출 없음 (로그에 `streamGenerateContent` 0회, 대화가 만들어지지 않음) |
| `agy --model gemini-3.8-flash -p "/boost hi"` | **같은 오류로 거부** — exit 1, 5초. 모델 검증이 슬래시 명령 확장보다 먼저라 `/boost` 를 붙여도 소용없다 |
| `agy --model gemini-3.8-flash --effort high -p "/boost hi"` | **성공** — exit 0, 10초. 로그에 `model alias "gemini-3.8-flash" resolved to "gemini-3.8-flash-high"`, `expanded slash command "boost" (system)`, 모델 호출 2회. 응답 첫 줄 `**Routine**: Solo Routine` |
| `agy --model claude-sonnet-4-6 -p "/boost hi"` (강도 변형이 없는 모델) | **성공** — exit 0, 11초. `--effort` 없이 받아들이고 `/boost` 를 확장했다. 응답 첫 줄 `**Routine: Solo** …` |
| `agy models` | 14줄 — `gemini-3.8-flash`·`gemini-3.7-flash`·`gemini-3.6-flash` 의 `-high`/`-medium`/`-low`, `gemini-3.1-pro-high`/`-low`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium` (전문은 `scripts/inttest/GeminiAssistTests.swift` 의 `agyModels20260914`). **기본 모델 표시가 없다.** "Fetching available models..." 는 stderr |
| `agy --help` | `--effort  Reasoning effort for the current CLI session (low\|medium\|high)`, `--model  Model for the current CLI session` — 둘 다 기본값 표기가 없다 |

- `--model` 없이 부를 때 쓰는 모델은 agy 내부 로그에만 보였다 (`agy models` 실행 로그의 `selected model override: label="Gemini 3.8 Flash (High)"`).
  공식 출력이 아니고 기본값인지 마지막 사용값인지도 가리지 못해 앱은 읽지 않는다.
- 앱의 규칙 (`AntigravityAdapter.plan`, 사용자 결정 2026-09-14):
  - 강도를 고르지 않으면 **High** 를 넘긴다 — CLI 기본 강도가 없어서 앱이 정한 값이며, 화면에도 CLI 기본값이 아니라 High 로 보인다.
  - ULTRA = `--effort high` + 프롬프트 앞 `/boost ` (위 셋째 줄). 강도 변형이 없는 모델은 `/boost` 만 (넷째 줄). High 가 없는 모델(`gpt-oss-120b`)에는 ULTRA 를 두지 않는다.
  - 모델을 고르지 않으면 목록에서 **가장 최신 Flash 제품군** (요약 기본 모델과 같은 규칙, 이날 목록에서 `gemini-3.8-flash`).
  - 넘길 강도를 정할 수 없으면 보내지 않고 이유를 보인다: 목록을 못 읽음, 목록에 없는 모델 + 강도 없음/ULTRA, High 가 없는 모델 + 강도 없음,
    agy 가 받지 않는 강도(옛 선택에 남은 `xhigh` 등), 강도가 붙은 옛 슬러그 + 다른 강도/ULTRA (슬러그와 `--effort` 는 conflicts).
  - `agy models` 조회가 실패하면 이전에 조회한 목록을 비우지 않는다 (앱 화면 판정과 실행 판정이 같은 목록을 본다).
- 확인하지 못한 것: 강도 하나짜리 슬러그(`gpt-oss-120b-medium`)를 제품군 + `--effort medium` 으로 넘기는 조합, 목록에 없는 강도(3.1 Pro 에 `medium`),
  `--model` 없이 `--effort` 만 주는 조합, 강도 변형 없는 모델의 `/boost` 없는 턴, 3.8 Flash 밖의 제품군을 강도 없이 주는 조합.
- 앱이 이 규칙대로 인수를 만드는지는 가짜 agy 스크립트로 확인한다 (`inttest offline` "Antigravity 요청 조립 · 인계 (가짜 agy)" — 입력창 보내기 ·
  ULTRA · 인계 전송이 넘긴 argv · stdin 을 그대로 본다).

### `/boost` — 헤드리스에서도 동작한다

`/boost` 는 복잡한 작업을 다중 에이전트 심층 추론 파이프라인으로 넘기는 슬래시 명령이다.
**Pro·Ultra 요금제 전용이고 토큰을 평소의 3~10배 쓴다** (가이드). 2026-09-12 실측:

| 방식 | 결과 |
|---|---|
| `agy -p "/boost"` | `status: SUCCESS`, 응답 "`/boost` mode is enabled. 작업을 알려달라" (입력 14,618 토큰) |
| stream-json 입력 `{"event":"user","message":{"content":"/boost"}}` | 동일하게 동작 |
| `--disable-slash-commands` 와 함께 | 확장되지 않는다 (플래그 설명 그대로) |

즉 앱에서는 **프롬프트 앞에 `/boost ` 를 붙이고 `--disable-slash-commands` 를 빼면** 쓸 수 있다.
위 두 줄은 `--model` 없이 한 것이다. 모델을 고른 채 쓰려면 제품군이면 `--effort` 도 함께 줘야 한다 —
강도 없이 `/boost` 만 붙이면 모델 검증에서 거부된다 (2026-09-14 실측, 위 "모델과 추론 강도").
요약 호출은 이 플래그로 슬래시 확장을 막고 있으므로 영향이 없다.
화면에서는 이 별도 명령을 보라색 **ULTRA**로 표시하고, 넘기는 값은 **High + `/boost`** 다 (슬라이더에서 High 뒤에 틈을 두고 따로).
`agy`가 지원하는 추론 강도 자체는 `low|medium|high`뿐이므로 Antigravity에 `max`를 만들지 않는다.

### 작업 에이전트로 쓸 때 (2026-09-12 실측)

```
agy --input-format stream-json --output-format stream-json
    --add-dir <프로젝트 경로>
    --dangerously-skip-permissions
    [--sandbox]
    --model <제품군> --effort <low|medium|high> | --model <강도 포함 슬러그> | --model <강도 변형 없는 모델>
    [--conversation <대화 ID>]
    --print-timeout 10m
stdin (한 줄):  {"event":"user","message":{"content":"[/boost ]<프롬프트>"}}
```

모델 · 강도는 `AntigravityAdapter.plan` 이 정한다 (2026-09-14): 제품군은 늘 `--effort` 와 함께 (고르지 않으면 `high`),
ULTRA 는 `--effort high` + content 앞 `/boost `, 모델을 고르지 않으면 목록의 가장 최신 Flash 제품군.
보낼 수 없는 선택은 프로세스를 띄우기 전에 막는다 (입력창 보내기 · 인계 전송 모두).

| 실측 | 결과 |
|---|---|
| 작업 폴더 | 프로세스 작업 폴더만으로는 파일을 찾지 못한다. **`--add-dir` 로 지정해야** `view_file ./x` 가 동작 |
| 폴더 안 읽기 | 허용 |
| 폴더 안 쓰기 | **자동 거절** — "a tool required the `write_file` permission that headless mode cannot prompt for" |
| `permissions.allow` 설정 | 헤드리스에서 **무시된다** ([이슈 #548](https://github.com/google-antigravity/antigravity-cli/issues/548)) |
| 승인이 필요한 도구 | 물을 방법이 없어 거절되거나 `--print-timeout` 까지 멈춘다 (작업 폴더 밖 `find_by_name` 이 2분간 멈춤) |
| `--dangerously-skip-permissions` | 파일 쓰기·명령 실행 모두 성공. **유일하게 동작하는 경로** |
| `--sandbox` 병행 | 편집 도구는 되지만 셸의 파일 쓰기는 거부 (`zsh:1: operation not permitted`). 에이전트가 `write_to_file` 로 우회 |
| 세션 재개 | `--conversation <id>` 로 이전 맥락 유지, 같은 `conversation_id` 반환. 재개하면서 `--model` 을 바꿔도 된다 (2026-09-20: 3.8 flash → 3.7 flash, 이전 내용 기억) |
| `--mode plan` (2026-09-20) | `--dangerously-skip-permissions` 와 함께 주면 **요청한 파일을 그대로 만든다.** 읽기 전용을 보장할 방법이 없어 앱은 Antigravity 의 읽기 전용 턴을 시작하지 않는다 (`AgentProvider.supportsReadOnlyTurns`) |
| 스트리밍 텍스트 | **1.3.2 부터 있다** (2026-10-09 실측, `scripts/probe/antigravity-stream`): `step_type == "agent_response"` 인 `step_update` 의 `text_delta` 가 본문 조각이다 — **증분**(누적 아님), ACTIVE 줄마다 하나 · DONE 줄에도 마지막 조각과 `duration_seconds` · `usage`. 조각을 이은 글 = 마지막 `result.response` (1261자로 확인). 앱은 조각을 흐르는 글로 넘기고 단계가 끝나면 그 단계의 글을 확정하며, 조각을 받은 턴은 `result.response` 를 다시 내지 않는다(`AntigravityAdapter.handleStep`). 그 전 판(1.2.x)은 `agent_response` 에 본문이 없고 `result.response` 로 한 번에 왔다 — 조각이 없으면 그대로 그것을 쓴다. 1.3.2 의 도구 · 생각 단계 모양은 재지 못했다 |
| 종료 코드 | `run_command` 완료 이벤트에 없다. 앱은 "종료 코드 미확인"으로 둔다 |

도구 이벤트 형태:

```jsonc
{"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE","step_type":"tool",
 "tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"echo hi"}}}}
{"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"tool",
 "tool_name":"run_command","duration_seconds":0.1,
 "tool_info":{"parameters":{"CommandLine":"echo hi"},"output":"hi\n"}}}
```

- 파일 편집 도구: `write_to_file`(`TargetFile`), `replace_file_content`, `multi_replace_file_content`.
- 읽기 도구: `view_file`(`AbsolutePath`), `list_dir`, `find_by_name`, `grep_search`.
- `state` 는 `ACTIVE → DONE | ERROR`. 앱은 `inProgress → completed | failed` 로 바꿔 화면 어휘에 맞춘다.

### 호출 기록이 로컬에 남는다

`agy` 는 헤드리스 호출마다 `~/.gemini/antigravity-cli/brain/<conversation_id>/` 를 만들고,
`.system_generated/logs/transcript_full.jsonl` 에 **사용자 메시지 원문 전체**를 저장한다.
앱이 보낸 (마스킹된) 대화 기록도 여기에 남는다. 앱은 다른 프로그램의 데이터 폴더를 지우지 않으며, 설정 화면에서 이 사실을 안내한다.

### 한도 조회 — `agy -p /usage` (2026-10-09 실측, agy 1.3.2)

예전(2026-09-12, agy 1.2.1)에는 `/usage` · `/quota` 를 대화형 명령으로만 보고 Antigravity 한도를 늘 "정보 없음" 으로 두었다.
헤드리스에서도 된다 (CodexBar 의 문서는 1.1.11 부터라고 적는다 — 이 Mac 에서 확인한 것은 1.3.2 뿐).

```
agy -p /usage --output-format json        (작업 폴더는 빈 임시 폴더, stdin 은 닫음)
```

- 7초 남짓, 종료 코드 0, `usage` 의 토큰이 모두 0, `conversation_id` 는 빈 값 — 모델을 부르지 않는다.
  `~/.gemini/antigravity-cli/brain/` 에 새 폴더도 생기지 않았다.
- Google 과 통신하므로 앱은 **Antigravity 를 허용한 프로젝트가 있을 때만** 부른다 (`LimitsService.antigravityEnabled` — `agy models` 와 같은 원칙).
- 응답 (실측, 설명 글은 줄임):

```
{"conversation_id":"","status":"SUCCESS",
 "response":"Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-15T06:55:15Z\n…",
 "duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,…,"total_tokens":0},
 "command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit and a 5-hour limit. …",
   "groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro",
              "buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly",
                          "remaining_fraction":0.9973227381706238,"reset_time":"2026-10-15T06:55:15Z"},
                         {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h",
                          "remaining_fraction":0.9989356994628906,"reset_time":"2026-10-09T19:04:20Z"}]},
             {"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
              "buckets":[{"id":"3p-weekly",…,"window":"weekly","remaining_fraction":1,…},
                         {"id":"3p-5h",…,"window":"5h","remaining_fraction":1,…}]}]}}}
```

- 한도는 **모델 묶음마다** 따로다 — Gemini 모델과 Claude · GPT 모델이 각자 주간 · 5시간 창을 갖는다.
  앱은 창마다 묶음 이름을 `LimitWindow.model` 에 적어(Claude 의 Fable 주간처럼) 계정 전체의 한도 도달로 세지 않고, 모든 묶음에 다 찬 창이
  있을 때만 한도 도달로 본다. 받는 쪽 사실 · 한도 줄의 초기화 시각은 그 대화 · 실행의 모델이 쓰는 묶음만 본다
  (`LimitSnapshot.scoped(toAntigravityModel:)` — `gemini-…` 는 Gemini, 그 밖은 Claude · GPT, 모델을 고르지 않았으면 앱 기본인 Gemini).
- `response` 의 글은 100% 로 반올림돼 있다 — 앱은 `command.data` 의 `remaining_fraction` 을 쓰고, 그것이 없을 때만 글을 읽는다.
- 모든 창이 100% 남음이어도 그대로 믿는다 (사용자 결정 2026-10-09 — 막 초기화됐거나 쓰지 않은 계정도 그렇다). 2026-05 포럼에
  "다른 위치에서 띄우면 늘 100% 로 나온다" 는 보고가 있으나(답 없음) 이 Mac 의 1.3.2 는 빈 임시 폴더에서 실제 값을 돌려줬다.
- 다른 앱(CodexBar 등)은 Antigravity 앱 · CLI 의 language_server 에 localhost RPC(`RetrieveUserQuotaSummary` — 프로세스 인수의
  CSRF 토큰)를 보내거나 OAuth 토큰으로 `cloudcode-pa.googleapis.com/v1internal` 을 부른다. 이 앱은 쓰지 않는다 — 문서화되지 않은
  내부 프로토콜이고, 뒤의 것은 Antigravity 로그인의 제3자 재사용이다.
- v0.1 은 **보이기만** 한다 (한도 칩 · 팝오버 · 메뉴바 · 현황 · 인계 카드의 받는 쪽 줄 · 한도 줄의 초기화 시각). 자동 인계 · 이어 가기
  제안의 대상에는 넣지 않았다 (사용자 결정 2026-10-09).
- 로그인이 안 된 계정 · 오류의 응답은 실측하지 못했다 — `status` 가 SUCCESS 가 아니거나 `error` 가 있으면 그 글을 `ErrorClassifier` 로 가르고
  원문을 남긴다.

---

## Claude Code — stream-json

### 실행

```
claude -p
  --input-format stream-json
  --output-format stream-json
  --verbose
  --include-partial-messages
  --permission-mode <manual|acceptEdits|plan>
  --permission-prompt-tool stdio
  [--session-id <uuid> | --resume <uuid>]
```

턴 하나당 프로세스 하나. `--session-id` 로 앱이 세션 ID 를 정하고, 다음 턴은 `--resume` 으로 잇는다.
`--bare` 는 이 환경에서 OAuth 와 사용자 설정을 읽지 않으므로 **사용하지 않는다**.

**읽기 전용 턴 · 구조화 응답 (2026-09-20 실측, claude 2.1.270).** 앱의 `AgentTurnRequest.readOnly` · `outputSchema`.

| 실측 | 결과 |
|---|---|
| `--disallowedTools Write Edit NotebookEdit Bash` | 파일을 만들라는 요청에도 쓰지 못한다. 승인 요청도 오지 않는다. **앱은 이것을 읽기 전용으로 쓴다** |
| `--disallowedTools` 의 위치 | 뒤따르는 값을 모두 도구 이름으로 삼키는 가변 인자다. 프롬프트를 위치 인자로 뒤에 두면 삼켜져 "입력 없음"으로 끝난다. 앱은 프롬프트를 stdin 으로 보내고 이 인자를 맨 끝에 둔다 |
| `--permission-mode plan` | 프로젝트 폴더 쓰기는 막지만 `~/.claude/plans/` 에 계획 파일을 쓰고, 응답이 "ExitPlanMode 를 쓸 수 없다"는 말로 채워진다. 읽기 전용 용도로는 쓰지 않는다 |
| `--json-schema <JSON>` | `result` 이벤트의 `structured_output` 에 스키마대로의 **객체**가 온다. `result` 본문에도 같은 JSON 글이 온다 |
| `--resume` + 다른 `--model` | 된다. 세션 ID 가 유지되고 이전 맥락을 참조한다 (haiku → sonnet) |
| 읽기 전용 턴 뒤 같은 세션의 보통 턴 | 정상적으로 쓴다 (인자가 턴마다 새로 가므로 남지 않는다) |

### 앱 → CLI (stdin, NDJSON)

```jsonc
{"type":"control_request","request_id":"init-…","request":{"subtype":"initialize"}}
{"type":"user","session_id":"","parent_tool_use_id":null,
 "message":{"role":"user","content":"…"}}

// 중단
{"type":"control_request","request_id":"interrupt-…","request":{"subtype":"interrupt"}}

// 승인 응답
{"type":"control_response","response":{"subtype":"success","request_id":"<요청 id>",
 "response":{"behavior":"allow","updatedInput":{…}}}}
{"type":"control_response","response":{"subtype":"success","request_id":"<요청 id>",
 "response":{"behavior":"deny","message":"…","interrupt":true}}}
```

### CLI → 앱 (stdout, NDJSON)

| `type` | 내용 |
|---|---|
| `system` / `init` | `session_id`, `model`, `tools`, `mcp_servers[].status`, `slash_commands` |
| `system` / `hook_response` | 훅 출력 |
| `system` / `task_*` · `background_tasks_changed` | 서브에이전트 · 백그라운드 작업의 수명 (아래 "서브에이전트 · 백그라운드 작업"). `ClaudeTurnTracker` 가 작업 표 · 남은 목록 · 실행의 끝 판정에 쓴다. 모르는 `task_*` 는 실행마다 종류별 한 번 안내로 남긴다 |
| `stream_event` | `content_block_delta.delta.text` (스트리밍 텍스트), `.thinking` |
| `assistant` | 확정 메시지. `content[]` 안에 `tool_use{id,name,input}` |
| `user` | `content[]` 안에 `tool_result{tool_use_id,content,is_error}` |
| `control_request` / `can_use_tool` | `request_id`, `tool_name`, `input`, `tool_use_id`, `permission_suggestions` |
| **`rate_limit_event`** | `rate_limit_info.unifiedWindows.{five_hour,seven_day}.{utilization,resetsAt}` — **구조화된 한도. `/usage` 텍스트 파싱보다 신뢰도 높음** |
| `result` | 아래 참고 |

### `result` 판정 규칙 (실측 기반)

```jsonc
{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed",
 "result":"…","duration_ms":1489,"session_id":"…",
 "modelUsage":{"claude-opus-5":{"inputTokens":2,"outputTokens":14,
   "cacheReadInputTokens":0,"cacheCreationInputTokens":3450,
   "thinkingTokens":0,"costUSD":0.03486,"costBasis":"list"}},
 "permission_denials":[…]}
```

- `usage.input_tokens` 와 `modelUsage.inputTokens` 는 **캐시 토큰을 제외한 값**이다. 중복 합산하지 않는다.
- `thinkingTokens` 는 출력의 부분집합이다. 총합에 더하지 않는다.
- **인증 실패에도 `subtype: success` 가 나온 사례가 있다.** `is_error`, `terminal_reason`, 본문을 함께 본다.
- **사용자 중단은 `is_error: true`, `terminal_reason: "aborted_streaming"`** 으로 나온다. 모델 실패로 집계하지 않는다.
- 중단 결과의 `usage = 0` 은 무사용을 보장하지 않는다. 미확정으로 둔다.
- 토큰 값이 소수로 올 가능성에 대비해 `Int`/`Double`/`NSNumber` 를 모두 받는다.

**OAuth 만료 (2.1.233 실측, 2026-09-12)** — 모델을 부르지 않고 CLI 가 오류를 응답처럼 내보낸다.

```jsonc
{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text",
  "text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},
 "error":"authentication_failed"}
{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","num_turns":1,
 "result":"Failed to authenticate: OAuth session expired and could not be refreshed"}
```

- 문구가 "authentication" 이 아니라 **"authenticate"** 라서 분류기가 놓쳤다 → `authenticat`·`oauth` 로 잡는다.
- `<synthetic>` 응답이 와도 인계 **수신으로 보지 않는다.** 인증 실패는 모델이 읽기 전에 끝나므로 `failed`(다시 보낼 수 있음).

### 서브에이전트 · 백그라운드 작업 (2026-09-22 실측, claude 2.1.270, `--model claude-sonnet-5`)

앱과 같은 인수 · 같은 환경(로그인 셸 PATH + `TERM=dumb`, CLAUDE* 변수 없음)으로 띄우되, 첫 `result` 뒤에도 프로세스를 끄지 않고 이후 출력을 기록했다. 실측 당시의 앱은 첫 `result` 에서 프로세스를 껐다. 지금(2026-09-23 이후)은 사람이 지켜보는 쓰기 턴이면 `result` 뒤에도 남은 작업(`background_tasks_changed` 목록)을 기다리고, CLI 가 연 후속 턴을 같은 실행으로 받아 목록이 비고 턴이 없을 때 끝낸다 (`ClaudeTurnTracker`, 사용량은 마지막 `result` 하나). 무인 · 읽기 전용 · 구조화 응답 턴은 지금처럼 첫 `result` 에서 끝낸다.

| 실측 | 결과 |
|---|---|
| `--permission-mode manual` | 받아들인다. `init` 에는 `permissionMode: "default"` 로 온다 |
| `init.tools` | `Task`(호출 이름은 `Agent`) · `Workflow` · `TaskStop` · `TaskOutput` · `Monitor` 등이 `-p` 에서도 있다. `ultracode` 라는 말은 `-p` 에서도 먹힌다 (Skill → Workflow 호출) |
| 일반 Agent 호출 (2개 병렬) | 서브에이전트 **안의** 호출이 `parent_tool_use_id` 가 붙은 `assistant`(`tool_use`) · `user`(`tool_result`, 서브에이전트에게 준 프롬프트는 `text`)로 온다. 서브에이전트의 **마지막 답은 따로 오지 않고** 메인의 Agent `tool_result` 로만 온다. 서브에이전트의 `stream_event` 조각은 오지 않는다 |
| 작업 이벤트 (`system`) | `task_started{task_id, tool_use_id, description, task_type: local_agent\|local_workflow\|local_bash, subagent_type \| workflow_name, is_backgrounded, owned_by_subagent?, prompt}` → `task_progress{description, usage{total_tokens,tool_uses,duration_ms}, last_tool_name}` → `task_updated{patch.status: completed\|killed}` → `task_notification{status: completed\|stopped, summary, output_file, usage}`. 일반(포그라운드) Agent 도 같은 이벤트를 낸다 |
| `background_tasks_changed{tasks:[{task_id, task_type, description}]}` | 남은 백그라운드 작업의 **전체 목록**. 바뀔 때마다 통째로 온다 |
| 백그라운드 Agent · Workflow | **작업이 남아 있어도 `result` 가 먼저 온다** ("launched" · "완료되면 알려드릴게요"). 작업이 끝나면 CLI 가 **스스로 새 턴**을 연다: `task_notification` → `system/init`(같은 `session_id`) → 답 → 두 번째 `result`(`origin: {"kind":"task-notification"}`, `result_index` 1) |
| 하위 안에서 **앞에서** 돈 Bash (2026-09-24, 설치본의 실제 기록) | 하위 에이전트가 `run_in_background` 없이 돌린 `sleep 10` 도 `task_started{task_type: local_bash, is_backgrounded: false, owned_by_subagent: true}` 로 온다 (백그라운드 하위 다섯이 저마다 하나씩). 앱은 이것을 그 하위의 한 걸음으로 보고(`SubAgentInfo.isInternalStep`) 목록 · 카드 · 하위 수에서 뺀다 |
| 후속 `result` 뒤에도 | 작업이 남을 수 있다 (서브에이전트가 띄운 백그라운드 셸 — `owned_by_subagent: true`. 끝나면 그 서브에이전트가 다시 깨어나 `task_started` 가 또 온다) |
| 워크플로 안의 에이전트 | 메시지를 내보내지 않는다. `task_progress` 만 온다 |
| `result.modelUsage` · `total_cost_usd` | **프로세스 누적**이다 (턴마다 커진다). `usage` 는 턴별. `queued_turn_count` 는 늘 0 (신호로 못 쓴다). 매 실행에 Haiku 항목(입력 약 1000토큰)이 끼어 있다 |
| 대기 중 `control_request{subtype:"stop_task", task_id}` | 된다. `control_response success {}`, 그 작업만 `killed`/`stopped`. 서브에이전트 소유 작업이면 그 서브에이전트가 알림을 받고 다시 돈다 |
| 대기 중 `interrupt` | 백그라운드 작업을 **모두** 멈춘다 (`stopped`). 응답 `{"still_queued":[]}`. **`result` 는 오지 않고** 후속 턴도 없다. 프로세스는 stdin 을 닫을 때까지 살아 있다 |
| 대기 중 stdin 닫기 | 이미 시작한 후속 턴은 마치고(`result`), 남은 작업을 멈춘 뒤 스스로 끝난다 (5초 남짓) |
| 대기 중 새 사용자 메시지 | 바로 처리해 답한다(`result`). 백그라운드 작업은 계속 돌고, 끝나면 후속 턴이 또 온다 |
| 읽기 전용 턴(`--disallowedTools Write Edit NotebookEdit Bash`) 의 서브에이전트 | 쓰기 도구가 없다 — 제한이 이어진다. `Workflow` 는 여전히 쓸 수 있다(승인 요청이 온다) |
| Workflow 호출 | `can_use_tool` 승인 요청이 온다 (`input.script` 에 스크립트 전체) |
| `stop_task` 뒤의 목록 (t5) | 빈 목록(`background_tasks_changed []`)이 온 뒤 약 10ms 만에 하위가 깨어나 같은 `task_id` 로 다시 찬다 → 앱은 빈 목록이 1.5초 그대로일 때만 끝으로 본다 (`ClaudeTurnTracker.emptyListDebounce`, 추정값) |
| `ambient` · `skip_transcript` (2.1.276 스키마, 실측 기록에는 없음) | `background_tasks_changed.tasks[]` · `task_started` · `task_notification` 에 붙는다. 아티팩트 감시(`monitor_ws`) 등은 스스로 끝나지 않는다 → 앱은 목록에서 `ambient` 항목만 빼고 기다리고(`skip_transcript` 만 붙은 항목은 기다린다), 어느 표시든 붙은 작업은 화면에 내지 않고 후속 턴도 기다리지 않는다 |
| 턴 도중에 끝난 메인 작업의 알림 | CLI 가 그 턴에 흡수할 수 있다 (`absorbed_mid_turn`) — 그러면 후속 턴이 열리지 않는다. 합성 시나리오로만 시험했다 |

### 로그인 확인

`claude auth status --json` → `{"loggedIn": false, "authMethod": "…", "apiProvider": "…"}` (로컬 확인, 토큰 사용 없음).
자동 인계는 Claude 를 대상으로 고르기 전에 이 값을 본다. 확인하지 못하면 로그인으로 보지 않는다.

### API 키로 실행 — Max · Team 의 월 API 크레딧 (2026-10-08 문서 확인 · 크레딧 차감은 사용자 확인)

앱은 모델 칩의 "API 크레딧으로 실행" 을 켠 대화의 Claude 실행에만 키체인의 키를 `ANTHROPIC_API_KEY` 로 넣는다 (`ClaudeAPIKey.environment` ← `RunSession.makeAdapter`). 근거는 공식 문서이고, **이 앱이 띄운 `claude -p` 가 크레딧에서 빠지는 것은 사용자가 확인했다** (2026-10-08 — Console 의 Promotional credits 에서 빠짐. 측정 방법 · 수치는 기록하지 않았다).

- 크레딧 (Claude Platform 문서 "API credits for Max and Team plans", 2026-10-07 갱신): Max 5x 월 $100 · Max 20x 월 $200 · Team 좌석별(합 최대 $500). claude.ai > 설정 > 결제에서 Console 조직을 연결하면 그 조직으로 들어오고 결제 주기마다 새로 들어오며 넘어가지 않는다. 그 조직의 모든 API 키가 같은 잔액을 쓴다.
- 무엇이 크레딧에서 빠지나 (도움말 17154008): `claude -p` · Agent SDK 를 **연결한 조직의 API 키로** 실행할 때. 구독으로 로그인한 채 실행하면 구독 한도에서 빠진다. 같은 문서는 Claude Code 의 GitHub Action · IDE 확장 · 데스크톱 앱이 띄운 실행은 `-p` 여도 Claude Code 사용으로 보아 크레딧 대상이 아니라고 한다 — 이 앱이 띄운 `claude -p` 는 크레딧에서 빠졌다 (사용자 확인 2026-10-08).
- 크레딧이 떨어지면: 구입한 크레딧이 없으면 요청이 멈춘다 (구독으로 넘어가지 않는다). API 의 글 `Your credit balance is too low to access the Anthropic API…`, Claude Code 의 글 `Credit balance too low · Add funds: …` — 앱은 성공 형식으로 와도 실패로 본다 (`ClaudeAdapter.cliFailureInSuccess` · `ClaudeAPIKey.isCreditExhausted`).
- 구독 한도에 닿은 대화를 이어 가기 (`ClaudeAPIContinue`, 2026-10-08): 그 대화의 Claude 세션 ID 는 한도로 끝난 실행에서도 남고(`result` 의 `session_id`), 인증이 구독에서 키로 바뀌어도 세션 기록은 이 Mac 의 `~/.claude/projects/…` 에 있어 `--resume` 으로 이어진다 — 앱은 "API 크레딧으로 실행" 을 켜고 같은 세션에 이어 가기 메시지 하나를 보낸다 (인증을 바꾼 재개 자체는 실측하지 않았다).
- 인증 순서 (Claude Code 문서 "Authentication precedence"): 클라우드 제공자 표시(`CLAUDE_CODE_USE_BEDROCK` · `_VERTEX` · `_FOUNDRY`) → `ANTHROPIC_AUTH_TOKEN` → `ANTHROPIC_API_KEY` → `apiKeyHelper` → `CLAUDE_CODE_OAUTH_TOKEN` → 프로필 → `/login` 구독. **`-p` 에서는 `ANTHROPIC_API_KEY` 가 있으면 늘 쓴다** (대화형은 한 번 묻는다). 그래서 앱은 키를 넣을 때 앞 순위의 둘(클라우드 제공자 표시 · `ANTHROPIC_AUTH_TOKEN`)을 그 실행에서 뺀다. 셸의 `ANTHROPIC_API_KEY` 를 쓰지 않는 것은 터미널의 대화형 claude 가 그 키로 넘어가면 크레딧 대상이 아닌 사용까지 그 키로 가기 때문이다.

### 모델 목록

`claude -p /model --output-format json` → `result` 텍스트:

```
Current model: `Opus 5` (effort: high)
Usage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID.
```

`Available:` 뒤의 쉼표 목록에서 별칭을 뽑는다. "or a full model ID" 같은 설명 문구는 제외한다.
추론 강도는 `--effort <low|medium|high|xhigh|max>` (CLI 도움말 기준).
`ultrathink`는 프롬프트/명령으로 고강도 사고를 요청하는 별도 기능이지 `--effort ultra` 값이 아니다.
따라서 Claude에는 없는 `ultra` 값을 만들어 넘기지 않는다. 대신 강도 목록 끝의 ULTRA 는 `--effort ultracode`다 (사용자 결정 2026-10-07 — Codex 의
ultra 와 같은 자리). 도움말(2.1.292)에는 다섯 값만 있지만 CLI 가 받는 숨은 별칭이다: `claude -p --effort ultracode /model`(비용 0)이
"(effort: xhigh)" 를 돌려주고, 모르는 값(`bogus`)처럼 경고하지 않는다. 번들을 읽으면 강도를 xhigh 로 두고 그 세션에 ultracode(동적 워크플로)를
켠다 — 계정의 워크플로 기능이 꺼져 있거나 모델이 받지 않으면 xhigh 로만 돈다(정적 읽기, 미실측). MAX 위의 강도가 아니므로 화면은 "Extra High +
워크플로" 라고 안내하고, 읽기 전용 · 구조화 응답 턴에는 `xhigh` 로 바꿔 넘긴다(`ClaudeAdapter.cliEffort` — 그 턴은 `Workflow` 를 막는다).
형식이 바뀌면 목록을 비우지 않고 대체 목록을 쓰되 대체본임을 표시한다.

### 명령 · 스킬 목록 (입력창 "/" 목록, 2026-10-07 실측, claude 2.1.292)

`claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence` 를 **그 폴더에서** 띄우고
`initialize` 제어 요청 하나만 보내면 응답(`control_response.response.response`)의 `commands` 에 명령 · 스킬이 온다. 모델을 부르지 않는다
(0.3초 남짓, SessionStart 훅은 돈다). stdin 을 닫으면 0.5초 안에 끝난다.

```jsonc
{"name":"code-review","description":"Review the current diff, …","argumentHint":"[target]","builtin":true}
{"name":"usage","description":"Show session cost, …","argumentHint":"","aliases":["cost","stats"],"builtin":true}
{"name":"pdf","description":"Use this skill whenever …","argumentHint":"","builtin":false}   // 플러그인 스킬
```

- `builtin` 은 "번들" 이라는 뜻이라 번들 스킬(code-review · simplify …)도 `true` 다 — 스킬과 명령을 가르는 값이 아니다. 실행의 `system/init` 에는
  이름만 든 `skills` · `slash_commands` · `terminal_slash_commands`(color · focus · reload-plugins · doctor — 터미널 전용)가 따로 온다.
- 실행(턴)마다 앱이 보내는 `initialize`(`init-…`)의 응답에도 같은 `commands` 가 온다 — 앱은 그것으로도 목록을 새로 받아 둔다(`AgentEvent.slashCommands`), 따로 띄우지 않는다.
- 걸리는 시간(같은 날 셸에서 세 번): 응답까지 0.26 ~ 0.54초 (첫 번째가 느리다). Codex `skills/list` 는 0.06 ~ 0.34초.
- MCP 서버의 프롬프트는 응답 뒤 `system/commands_changed` 로 더 온다 (이름에 빈칸 — "claude.ai <커넥터>:… (MCP)"). 앱은 응답의 목록만 쓴다.
- 앱은 터미널 전용 · 앱이 턴마다 정하는 것(model · effort · fast) · clear(앱은 세션 ID 로 잇는다)를 뺀다 (`SlashCommands.claudeHidden`).
- 보낼 때는 사용자 메시지 글 그대로 — 맨 앞의 "/이름 인수" 를 CLI 가 펼친다. stream-json 의 사용자 메시지로도 된다 (임시 폴더의
  `.claude/skills/ahc-probe` 로 확인 — `--replay-user-messages` 의 되돌림은 `<command-name>/ahc-probe</command-name>…<command-args>banana` 꼴,
  `isReplay: true`). 글 앞에 무엇을 붙이면 명령이 아니게 되므로 앱의 안내(작업 폴더 이동)는 다음 턴으로 미룬다.

### 한도 조회

`claude -p /usage --output-format json` — 바깥은 JSON 이지만 `result` 안의 한도 정보는 **텍스트**다.

```
Current session: 28% used · resets Sep 9 at 5:10pm (Asia/Seoul)
Current week (all models): 76% used · resets Sep 11 at 10am (Asia/Seoul)
```

형식이 바뀌면 0% 가 아니라 "정보 없음 + 원문 확인"으로 대체한다.

**모델 한도 줄 (2026-09-22 실측).** 전체 주간 아래에 모델 하나의 주간 한도가 붙는다.

```
Current week (all models): 56% used · resets Sep 25 at 10am (Asia/Seoul)
Current week (Fable): 76% used · resets Sep 25 at 10am (Asia/Seoul)
```

앱은 이 줄을 `LimitWindow.model = "Fable"` 인 구간으로 보이기만 하고, **Claude 전체의 한도 도달 판정(`LimitSnapshot.reachedAccountWideCap`)에는 넣지 않는다** — Fable 이 다 차도 다른 모델은 쓸 수 있다. 그래서 자동 인계 대상 · 자동 작업 가용성도 Fable 구간으로는 Claude 를 빼지 않는다 (Fable 로 도는 대화가 Fable 이 찬 Claude 로 넘어갈 수 있다 — 모델까지 보는 판정은 아직 없다). 같은 주의 `rate_limit_event` 에는 Fable 구간이 없었다 (`unifiedWindows` 는 `five_hour` · `seven_day` 뿐). Fable 한도에 걸렸을 때의 오류 문구는 아직 관찰하지 못했다 (`ErrorClassifier` 의 `"fable limit"` 은 추정).

**버전에 따라 다르다 (2026-09-12 이 Mac 실측).**

| 버전 | `-p /usage` 결과 |
|---|---|
| 2.1.233 | 구독 한도 대신 **세션 비용 통계**만 (`Total cost: $0.0000 …`). 짧은 턴을 실행해도 `rate_limit_event` 가 오지 않아 **한도를 알 방법이 없었다** |
| 2.1.269 | 위 형식대로 정상 (`Current session: 30% used · resets …`, `Current week (all models): 28% used · …`) |

한도를 읽지 못하는 버전에서는 "정보 없음"으로 표시하고 자동 인계 후보에서 뺀다.
조회가 형식 문제로 실패해도 30분 안에 받은 실제 값(실행 중 `rate_limit_event` 포함)은 지우지 않는다
(`LimitsService.mergedAfterRefresh`).

---

## Codex — `codex app-server --stdio`

JSON-RPC 유사 프로토콜. **`jsonrpc` 필드는 쓰지 않는다** (실측 형태와 동일하게 맞춤).
전체 스키마는 `codex app-server generate-json-schema --out <dir>` 로 생성할 수 있다.

### 흐름

```
initialize{clientInfo}  →  initialized(알림)
  →  thread/start{cwd,sandbox,approvalPolicy,model}  |  thread/resume{threadId,cwd,…,excludeTurns}
  →  turn/start{threadId,input:[{type:"text",text}]}
  →  (알림 소비)  →  turn/completed
turn/interrupt{threadId,turnId}
account/read{refreshToken:false}  →  account/rateLimits/read     (한도 조회 — 같은 프로세스에서 둘 다)
```

- `sandbox`: `read-only` | `workspace-write` | `danger-full-access`
- `approvalPolicy`: `untrusted` | `on-request` | `never`

**읽기 전용 턴 · 구조화 응답 (2026-09-20 실측, codex-cli 0.154.0).** `turn/start` 는 `sandboxPolicy` · `approvalPolicy` · `model` · `cwd` · `outputSchema` 도 받는다 (`codex app-server generate-json-schema` 로 확인).

| 실측 | 결과 |
|---|---|
| `turn/start` 의 `sandboxPolicy: {"type":"readOnly"}` | 셸의 파일 쓰기가 막힌다. `approvalPolicy: "never"` 를 함께 주면 승인 요청도 오지 않는다 (승인을 물으면 사람이 샌드박스 밖 실행을 허락할 수 있으므로 앱은 함께 준다) |
| 턴 단위 덮어쓰기의 수명 | **같은 프로세스의 이후 턴에도 남는다** — 덮어쓰기 없이 보낸 다음 턴의 쓰기도 실패했다 (스키마 설명: "this turn and subsequent turns") |
| 새 프로세스에서 `thread/resume` 에 `sandbox: workspace-write` | 쓰기가 되살아난다. 앱은 턴마다 프로세스를 새로 띄우고 재개할 때 샌드박스를 다시 넘기므로 읽기 전용이 뒤 턴으로 새지 않는다 |
| `turn/start` 의 `outputSchema` (객체) | 마지막 `agentMessage` 의 `text` 가 스키마대로의 JSON 글이다. 별도 필드는 없다 |

### 계정 조회 — `account/read` (2026-10-07 실측, codex-cli 0.160.1)

앱은 계정의 이메일 · 플랜을 이것으로 묻는다 (`LimitsFetcher.fetchCodexWithAccount` → `CodexAccountService.applyAccountRead`). 예전에는 `auth.json` 의 `id_token`(JWT)을 로컬에서 풀어 읽었다. 로그인 여부는 지금도 `auth.json` 에 자격 정보가 있는지로 본다 (토큰은 풀지 않는다 — 프로세스 · 네트워크 없이, 시작 점검표가 5초마다 본다). 실측 도구는 앱 밖의 Python 스크립트(app-server 를 앱과 같은 순서로 띄우고, 로컬 CONNECT 프록시로 바깥 연결을 적고, `sandbox-exec` 로 네트워크를 막아 봤다)였고, 등록된 실제 계정 둘(ChatGPT plus)과 빈 홈 셋(파일 · `keyring` · `auto` 저장)을 썼다.

- 요청 `{"method":"account/read","params":{"refreshToken":false}}` — `refreshToken: true` 면 답하기 전에 토큰을 새로 받는다(스키마 설명). 앱은 `false`.
- 답 (ChatGPT 로그인): `{"account":{"type":"chatgpt","email":"…","planType":"…"},"requiresOpenaiAuth":true,"workspaceRouting":{"chatgptAccountId":"…","backendOrigin":"https://chatgpt.com","accountRoutingOverride":"NO_CONSTRAINT"}}`. 스키마의 `account` 는 `apiKey` · `chatgpt` · `amazonBedrock` 셋 가운데 하나 또는 `null` (`codex app-server generate-json-schema` 의 `v2/GetAccountResponse.json`).
- 답 (로그인 안 됨): `{"account":null,"requiresOpenaiAuth":true,"workspaceRouting":null}` — 파일 · `keyring` · `auto` 저장 모두 같았다.

| 실측 | 결과 |
|---|---|
| 값이 `id_token` 을 풀어 읽던 것과 같은가 | 두 계정 모두 이메일 · 플랜 · 계정 ID(`workspaceRouting.chatgptAccountId` = `auth.json` 의 `tokens.account_id`)가 같다. `id_token` 의 만료 시각은 답에 없는데, 두 계정 모두 이미 지난 날짜(10-01 · 10-02)였고 로그인은 멀쩡했다 — 판정에 쓸 값이 아니었다 |
| `auth.json` 을 고쳐 쓰는가 | 모든 실행에서 해시 · 수정 시각 그대로 (`refreshToken` 을 `false` 로 주든 빼든) |
| 바깥 연결 | **app-server 가 시작할 때** 스스로 붙는다 — 로그인된 홈은 `chatgpt.com` 7번, 빈 홈은 `chatgpt.com` 1번 · `github.com` 2번. `account/read` 요청 자체는 새로 붙지 않는다 (시작 뒤 1.5초를 기다리고 보내면 7 ~ 11ms, 연결 0) |
| 시작하자마자 보내면 | 0.3 ~ 0.8초 — 시작할 때의 연결이 끝나기를 기다렸다가 답한다 |
| 네트워크를 막으면 (`sandbox-exec`) | 로그인된 계정: 곧바로 오류 `{"code":-32603,"message":"workspace routing discovery failed"}` — "로그인 안 됨" 이 아니다. 로그인 안 된 홈: `account: null` 로 정상 응답. 같은 때 `account/rateLimits/read` 도 실패한다 |
| 측정하지 못한 것 | 키체인(`cli_auth_credentials_store = "keyring"`)에 로그인한 상태 — 그 홈에 사람이 로그인해야 한다. API 키 · Bedrock 계정(이 Mac 에 없다) |

그래서 앱은: 한도를 읽는 같은 app-server 에 `account/read` 를 먼저 보내고(프로세스 · 연결이 늘지 않는다, 한도 답 뒤 최대 2초만 더 기다린다), 오류나 모르는 형식이면 지난 이메일 · 플랜을 그대로 둔다. 로그인 여부는 바꾸지 않는다. `auth.json` 의 `tokens.account_id` 가 바뀌면(다른 계정으로 다시 로그인) 이메일 · 플랜을 지우고 다음 조회를 기다린다. 시험은 `OfflineTests` 의 `codexAccountRead` · `codexAccountReadWithLimits`(가짜 app-server).

### 주요 알림

| method | 내용 |
|---|---|
| `thread/started`, `turn/started` | `thread.id`, `turn.id`, `model` |
| `item/agentMessage/delta` | 스트리밍 텍스트 |
| `item/reasoning/summaryTextDelta` | 추론 요약 |
| `item/started` / `item/completed` | `item.type` = `userMessage`, `agentMessage`, `commandExecution`, `fileChange`, `mcpToolCall`, `reasoning`, `error` |
| `thread/tokenUsage/updated` | `tokenUsage.total`(세션 누적) / `.last`(마지막 API 요청 1회) |
| `account/rateLimits/updated` | `primary`/`secondary` `{usedPercent, windowDurationMins, resetsAt}` |
| `turn/completed` | `turn.status` = `completed` \| `interrupted` \| `failed` |
| `mcpServer/startupStatus/updated` | MCP 서버 상태 |

### 사용량 계산 (실측 확인)

`total` 은 세션 누적, `last` 는 마지막 API 요청 1회분이다.
**턴 사용량 = 그 턴 동안의 `last` 합계 = `total` 증가분.**
실측: `total` 21,314 → 44,986 → 68,854 → 92,824, `last` 합계 = 71,510 (일치).

중복 이벤트로 인한 이중 합산을 막기 위해 **`total` 이 증가할 때만 `last` 를 더한다.**
단 이것만으로는 재개한 세션의 과거 사용량을 막지 못한다 — `thread/resume` 직후 **이전 턴의 알림이 한 번 다시 오고**(c13, 아래 "하위 에이전트 · 백그라운드 작업") 누적기는 0 에서 시작한다.
그래서 앱(`CodexTurnTracker`, 2026-09-23)은 **이 프로세스에서 시작한 턴(`turnId`)의 알림만** 세고, 하위 에이전트 스레드는 `total` 이 따로 누적되므로 **스레드마다** 누적기를 두어 합친다.
`inputTokens` 는 `cachedInputTokens` 를 **포함**하므로 순수 입력만 남긴다.
`reasoningOutputTokens` 는 출력의 부분집합이다.

### 서버 → 클라이언트 요청 (반드시 응답)

| method | 응답 |
|---|---|
| `item/commandExecution/requestApproval` | `{"decision":"accept"\|"acceptForSession"\|"decline"\|"cancel"}` |
| `item/fileChange/requestApproval` | 동일 |
| `item/permissions/requestApproval` | `{"permissions":{…},"scope":"turn"\|"session"}` (요청 프로필을 그대로 승인) |
| `item/tool/requestUserInput` | `{"answers":{"<질문 id>":"<답변>"}}` |
| `mcpServer/elicitation/request` | `{"action":"accept"\|"decline"\|"cancel","content":{…}}` |

모르는 요청은 조용히 승인하지 않고 JSON-RPC 오류로 거절하며 사용자에게 안내를 남긴다.

### 모델 목록

`model/list` → `result.data[]`:

```jsonc
{"id":"gpt-6-astra","model":"gpt-6-astra","displayName":"GPT-6-Astra",
 "description":"Our most capable model for complex, demanding work.",
 "hidden":false,"isDefault":true,"defaultReasoningEffort":"low",
 "supportedReasoningEfforts":[{"reasoningEffort":"low","description":"…"}, …]}
```

`hidden: true` 인 모델은 목록에서 제외한다.
추론 강도는 **모델마다 다르다** (`gpt-5.5` 는 `ultra`/`max` 를 지원하지 않는다).
현재 `gpt-6-astra`·`gpt-5.6-sol`·`gpt-5.6-terra`는 `max` 다음에 `ultra`도 제공한다.
`max`는 최대 추론 깊이, `ultra`는 최대 추론에 자동 작업 위임을 더한 단계로 설명된다.
선택한 모델은 `thread/start` · `thread/resume` · `turn/start` 의 `model`,
추론 강도는 `turn/start` 의 `effort` 로 전달한다.

### 스킬 목록 · 스킬 입력 (입력창 "/" 목록, 2026-10-07 실측, codex-cli 0.160.1)

`skills/list` `{"cwds":[<폴더>]}` → `result.data[] = {cwd, skills[]}`. 스킬 하나:

```jsonc
{"name":"documents:documents","description":"…","path":"/…/skills/documents/SKILL.md","scope":"user","enabled":true,
 "pluginId":"documents@openai-primary-runtime",
 "interface":{"displayName":"Documents","shortDescription":"Create and edit Word and Google Docs files",
              "defaultPrompt":"Use $documents to …", …}}
```

- `enabled: false` 는 뺀다. `scope` 는 user · repo · system · admin.
- Codex 의 스킬 표시는 "$이름" 이다 (TUI 의 "/" 명령은 app-server 에 없다). `turn/start` 의 `input` 에 글과 함께
  `{"type":"skill","name":…,"path":…}` 를 넣는다 (스키마 `UserInput` 의 `SkillUserInput`). 앱은 글 속 "$이름" 이 목록의 스킬이면 이것을 덧붙인다
  (`SlashCommands.codexMentions` → `CodexAdapter.turnParams`) — 실제 턴에서 스킬이 쓰였는지는 미실측.

### 중단 타이밍

`turn/start` **응답 직후** 보낸 `turn/interrupt` 는 `no active turn to interrupt` 로 실패한다.
어댑터는 **메인 스레드의** `turn/started` 알림으로 턴이 실제 활성화될 때까지(최대 6초) 기다렸다가 보내고
(`CodexTurnTracker.interruptTarget` — `turn/start` 응답은 턴 ID 만 알려 주고 활성으로 치지 않는다 · `mainTurnConfirmed`),
그 안에 활성화되지 않으면 프로세스를 정리한 뒤 `cancelled_before_active` 로 마감한다.
턴 ID 는 메인 턴의 것만 쓴다 — 하위 스레드의 `turn/started` 로 덮이면 `-32600` 으로 거절된다(c12, 2026-09-23 이전의 결함).
메인 턴이 끝나고 하위 · 백그라운드 명령을 기다리는 중이면 `turn/interrupt` 를 보내지 않고, 먼저 끝난 하위의 답을 넣은 뒤(최대 5초) app-server 를 끈다 — 하위 · 명령도 함께 끝난다(c7 · c9 · c11).

### 하위 에이전트 · 백그라운드 작업 (2026-09-23 실측, codex-cli 0.154.0, `gpt-5.6-terra`)

앱과 같은 순서 · 기본값(`workspace-write` · `on-request`)으로 app-server 를 띄우되, 메인 스레드의 `turn/completed` 뒤에도 끄지 않고 기록했다. 도구와 기록은 [`scripts/probe/codex-background/`](../scripts/probe/codex-background/README.md), 앱의 대응은 아래 "앱의 처리". CLI 기능 `multi_agent`(하위 에이전트) · `unified_exec`(백그라운드 터미널)은 안정 단계이고 기본으로 켜져 있다.

앱의 처리(2026-09-23 — 그 전에는 알림을 스레드로 가르지 않아 첫 하위의 `turn/completed` 에서 끝났다): `CodexTurnTracker` 가 메인(`thread/start` · `resume` 이 돌려준 스레드) · 하위 스레드를 가른다. 실행은 **메인** `turn/completed` 뒤, 진행 중인 하위 턴과 `item/completed` 가 오지 않은 메인 명령이 모두 끝날 때 끝난다 (사람이 지켜보는 쓰기 턴만 기다린다). 끝내기 전에 기다리지 않은 하위의 최종 답(하위 `turn/completed` 의 `turn.items` 중 `agentMessage{phase: "final_answer"}`)과 메인이 남긴 백그라운드 명령의 결과를 `thread/inject_items` 로 메인 스레드에 넣는다. MCP 안내는 메인 것만 남긴다.

| 실측 | 결과 |
|---|---|
| 하위 에이전트 = **별도 스레드** | 모델이 하위 에이전트 도구로 띄운다. 하위 스레드는 부모의 모델 · 강도(ultra 포함) · 샌드박스(읽기 전용 포함) · 폴더를 물려받는다. `thread/read` 로 보면 `parentThreadId`, `agentNickname`, `source: {"subAgent": {"thread_spawn": {parent_thread_id, depth, agent_path: "/root/<이름>", …}}}` |
| 하위 스레드의 알림 | **같은 연결로, 하위 스레드 ID 를 달고** 온다: `thread/status/changed` · `turn/started` · `item/started`/`item/completed` · `item/agentMessage/delta` · `thread/tokenUsage/updated` · `turn/completed` · `mcpServer/startupStatus/updated`(하위마다 MCP 서버를 다시 띄운다). **`thread/started` 는 오지 않는다** |
| 메인 스레드의 항목 | `subAgentActivity{kind: started \| completed \| interacted, agentThreadId, agentPath}` (띄울 때 · 끝날 때), `collabAgentToolCall{tool: "wait", status}` (기다릴 때. 이 버전에서는 `receiverThreadIds` · `agentsStates` 가 비어 온다). 띄우는 호출 자체는 `collabAgentToolCall(spawnAgent)` 가 아니라 `subAgentActivity started` 로 온다 |
| 사용량 | `tokenUsage.total` 은 **스레드마다 따로** 누적된다. 메인과 하위의 알림이 섞여 오므로 "total 이 커질 때만 더한다"는 규칙은 스레드별로 적용해야 한다. 같은 total 의 알림이 두 번 오기도 한다 (c3) |
| 기다리지 않는 하위 에이전트 | 메인 `turn/completed` 가 먼저 온다. 하위는 app-server 가 살아 있는 동안 계속 돌고, 끝나면 메인 스레드에 `subAgentActivity completed` 항목(이미 끝난 메인 턴의 `turnId`)만 온다. **Claude 와 달리 후속 턴이 저절로 열리지 않는다** (45초 관찰) |
| 하위의 최종 답이 메인에게 가는 길 | 턴을 일으키지 않는 메시지(`inter_agent_communication_metadata{trigger_turn: false}` + `agent_message{author: "/root/<이름>", recipient: "/root"}`, 본문 `Message Type: FINAL_ANSWER / Task name / Sender / Payload`)로 **메인 대기열**에 들어간다. app-server 는 이것을 알리지 않는다. 메인 기록에는 **메인의 다음 턴이 끝날 때** 붙어서, 그 턴은 모르고(c14 "UNKNOWN") **다다음 턴부터** 안다(c16). 그 전에 app-server 가 꺼지면 사라진다 — 재개한 턴도 모른다(c15) |
| `thread/inject_items{threadId, items}` | "Raw Responses API items to append to the thread's model-visible history". developer 메시지 하나(`{"type":"message","role":"developer","content":[{"type":"input_text","text":…}]}`)를 넣으면 응답 `{}`, 턴 · 모델 호출 없음. **끄고 새 프로세스에서 재개한 바로 다음 턴이 그 내용을 안다** (c17) |
| 강도별 위임 지시 | 메인 턴의 개발자 지시(`<multi_agent_mode>`)가 강도에 따라 다르다. low: "사용자 · AGENTS.md · 스킬이 명시적으로 요청하지 않으면 하위 에이전트를 띄우지 말라". **ultra: "능동적 위임 모드가 켜졌다 — 병렬로 나눌 수 있으면 위임하라"** (c1 · c3 의 rollout). 지시에 적힌 도구는 `spawn_agent` · `followup_task` · `send_message` · `wait_agent` · `interrupt_agent` · `list_agents` (이번 기록의 `collabAgentToolCall` 은 `wait` 뿐) |
| 백그라운드 터미널 (`unified_exec`, 짧은 yield) | 턴이 끝나도 명령은 app-server 의 자식으로 계속 돈다. 끝나면 **턴 밖에서** 그 명령의 `item/completed` 가 온다. 후속 턴 없음 |
| 메인 턴 `turn/interrupt` | 메인만 `interrupted`. 하위 에이전트는 멈추지 않고 끝까지 돈다 |
| 하위 턴 `turn/interrupt{threadId: 하위, turnId: 하위 턴}` | 그 턴은 곧바로 `interrupted`. **그 턴이 돌리던 셸 명령은 끝까지 돈다** (app-server 가 살아 있으면) |
| `turn/interrupt{threadId: 메인, turnId: 하위 턴}` | `-32600 "expected active turn id <하위 턴> but found <메인 턴>"` 로 거절 |
| stdin 닫기 · SIGTERM | app-server 가 1초 안에 끝나고, 하위 에이전트 · 백그라운드 터미널의 프로세스도 함께 죽는다. 남는 프로세스 없음 (Claude 는 진행 중인 후속 턴을 마치고 끝났다) |
| 하위가 도는 중 새 `turn/start` | 바로 처리해 답한다. 하위는 계속 돈다 |
| 새 프로세스에서 `thread/resume` | 하위 스레드는 다시 올라오지 않는다 (`thread/loaded/list` 에 메인만). 모델이 하위를 `wait` 하면 시간 초과만 받는다 — 하위가 죽었는지 알 수 없다 |
| `thread/resume` 직후 | **이전 턴의 `thread/tokenUsage/updated` 가 한 번 다시 온다** (`turnId` = 이전 턴, 값도 이전 턴의 마지막 알림과 같다). `thread/goal/cleared` 도 온다 |


## Claude: 이어받은 세션에 남은 작업 알림 · 우리 메시지 되돌림 (2026-09-29 실측, CLI 2.1.283)

전 실행의 백그라운드 작업이 끝나지 않은 채 프로세스가 끝나면(첫 result 에서 끝낸 턴 · 앱 종료), 그 작업은 세션에 남는다.
그 세션을 `--resume` 으로 이어받으면 CLI 는 우리 메시지보다 **먼저** 남은 알림을 한 턴으로 처리한다:

```
system task_notification (그 옛 작업 · status=stopped 등)
system init
result            ← 남은 알림의 턴 (빈 답 · num_turns 0, 또는 "No response requested." 같은 말)
system init
user (isReplay)   ← --replay-user-messages: 우리 메시지를 처리하는 턴 안에서 되돌려 준다
assistant …
result            ← 우리 메시지의 결과
```

첫 result 에서 끝내면 우리 메시지는 처리되지 않고 프로세스와 함께 버려진다. 앱은 `--replay-user-messages` 를 넘기고, 이번 실행이
띄우지 않은 작업의 알림을 봤으면 되돌림이 온 턴의 result 에서만 끝낸다 (`ClaudeTurnTracker`). 되돌림은 stdin 으로 보낸 사용자
메시지만 — CLI 가 스스로 연 후속 턴(작업 끝 알림)에는 없다. 이미지 블록(`{"type":"image","source":{"type":"base64",…}}`)을 담은
사용자 메시지도 stream-json 입력으로 받는다 (haiku 로 확인).
