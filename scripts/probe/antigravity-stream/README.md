# Antigravity(agy) stream-json 흐르는 글 실측

agy 1.3.2 의 stream-json 출력이 응답 본문을 조각으로 흘려 보내는지 잰 기록이다 (2026-10-09, 한 번).
`AntigravityAdapter` 의 흐르는 글 처리와 재생 시험 `scripts/inttest/AntigravityStreamTests.swift` 의 근거다.

- 명령: 앱과 같은 인수 — `agy --input-format stream-json --output-format stream-json --add-dir <폴더> --model gemini-3.8-flash --effort low --print-timeout 2m`, 표준 입력에 `{"event":"user","message":{"content":"…"}}` 한 줄을 쓰고 닫았다.
- 프롬프트: 등대에 관한 짧은 세 문단을 도구 없이 쓰라는 영어 글 (도구 단계 · 생각 단계가 없는 턴).
- 결과: 종료 0, stderr 비어 있음.

## 기록 `logs/s1.jsonl`

한 줄 = `{"t": 시작부터의 초, "ev": agy 가 낸 JSON 한 줄}` (`ProbeLogs` 형식). `init` 의 `cwd` 는 사용자 이름이 든 임시 경로라
`/tmp/agy-stream/work` 로 바꿨다. 그 밖에는 손대지 않았다.

| 무엇 | 실측 |
|---|---|
| 이벤트 | `init` 1(`model` · `cwd` · `tools` · `permission_mode: "request-review"`) → `step_update` 61 → `result` 1 |
| `step_update` | step 0 `user_input` DONE, step 1 `agent_response` ACTIVE 59 + DONE 1 |
| 조각 | `step_type == "agent_response"` 인 `step_update` 의 `text_delta` — **증분**(누적 아님). DONE 줄에도 마지막 조각과 `duration_seconds` · `usage` 가 있다 |
| 확정 | `result.response` = 조각 60개를 이은 글과 정확히 같다(1261자). `result.status` "SUCCESS" · `usage` · `conversation_id` · `num_turns` |
| 타이밍 | 첫 출력(init)까지 약 7.4초, 조각은 약 25ms 박자로 2.3초 동안, 프로세스는 `result` 뒤 약 1초 더 산다 |

재지 못한 것: 1.3.2 의 도구 단계 · 생각(thinking) 단계 모양 — 프롬프트에 도구가 없었고 low 강도라 thinking 0.
