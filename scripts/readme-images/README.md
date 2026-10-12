# README 소개 이미지

`docs/images/` 의 GitHub 소개 이미지를 **실제 앱 화면**으로 다시 만든다. 앱 화면이 바뀌면 이것 하나만 실행한다.

```bash
bash scripts/readme-images/make.sh
```

미리보기 번들 ID 의 Debug 빌드를 `AHC_OFFLINE=1` · 임시 DB · 임시 저장소로 띄워 창을 찍고([화면 확인 도구](../preview/README.md)와 같은 방식),
앱의 라이트 팔레트 색 · 그림자로 문구와 합성한다. 사용자 앱 · 실제 DB · 실제 `~/.codex` · CLI 는 건드리지 않는다.
필요한 것: 화면 기록 권한, Google Chrome, `python3` + Pillow, 1440×920pt 창이 들어가는 화면. 약 3분.

이미지마다 한국어 제목판(`<이름>.png` — README.ko.md)과 영어 제목판(`<이름>-en.png` — README.md)을
함께 만든다. 영어판도 앱 화면은 v0.1 의 한국어 그대로이고, 합성한 제목 · 부제만 영어다 (문구는 `compose.py` 의 `TEXT`).

| 결과 (`docs/images/`) | 장면 |
|---|---|
| `hero.png` · `hero-dark.png` | 앱 이름 + 전체 창 (라이트 · 다크) |
| `agents.png` | 한 대화에서 Claude → Codex → Antigravity 가 번갈아 일한 대화 |
| `handoff.png` | Claude 한도 도달 직후 대화 끝의 인계 카드 (앱의 규칙 초안 그대로) |
| `relay.png` | 한도 도달 → 인계 줄 → Codex 가 이어받아 끝낸 대화 |
| `changes.png` | 크게 보기 diff + 변경사항 탭 커밋 |
| `social-preview.png` | 저장소 Settings → Social preview 용 1280×640 (저장소에는 `social-preview-en.png` 를 올린다) |

| 파일 | 책임 |
|---|---|
| `make.sh` | 빌드 → seed → 시나리오 저장소 · 임시 DB → 캡처 → 합성 순서 |
| `scenario.sh` | `moa-ios` 저장소(`feature/login-retry`, 업로드할 커밋 2개)와 Claude · Codex 가 할 변경(단계 A · B), 사이드바용 다른 프로젝트 |
| `seed/main.swift` | 앱의 비 UI 소스와 함께 컴파일되는 seed. `Store` 로 대화 · 실행 · 사용량을 넣고, 인계 문서는 `HandoffPacketBuilder`, 실행별 변경은 단계를 실제로 적용하며 찍은 `RunFileSnapshot` 으로 만든다 |
| `shoot.sh` | DB 사본 · 데모 `CODEX_HOME` 으로 앱을 뒤에서 띄워 창 하나를 찍는다 |
| `compose.py` | 캡처에서 필요한 부분을 잘라 HTML 로 합성하고 헤드리스 Chrome 으로 2배율 PNG 를 뽑는다 |

- 자르는 영역은 지금 창 배치(사이드바 · 인스펙터 폭) 기준 좌표다. 배치가 바뀌면 `compose.py` 의 `RELAY_BOX` · `CHANGES_BOX` · agents 좌표를
  확인한다 — 글줄 한가운데나 단추 · 줄 번호에 걸리지 않게 빈 자리에서 자른다. 인계 카드는 앱이 적어 둔 카드 자리(`-preview.cardFrameFile`)로 자른다 — 기록이 없거나 카드가 캡처 밖이면 멈춘다.
- 대화는 맨 아래로 스크롤된 채 찍히므로 hero 창 높이(`make.sh` 의 `HERO_SIZE`)가 대화의 맨 위가 잘리는 자리를 정한다. 대화 내용이나 배치가
  바뀌면 hero 의 맨 위(툴바 바로 밑)에서 글줄이 반쯤 잘리지 않는지 확인하고 높이를 맞춘다.
- 오프라인 미리보기는 한도를 조회하지 않으므로 `make.sh` 의 `LIMITS`(`-preview.limits` — Claude 다 참 · Codex 12%)와
  `AGY_USAGE`(`-preview.agyUsage` — `agy -p /usage` 응답 모양, Antigravity 19%)를 넣는다. 툴바 한도 칩 · 한도 도달 줄의 초기화 시각 ·
  인계 카드의 받는 쪽 사용률이 이 값이다 (초기화 시각은 찍는 때 기준이라 찍을 때마다 바뀐다).
- 에이전트 로고는 앱이 그리는 그대로 찍힌다 (각 회사의 상표다 — [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)).
- 글꼴은 환경 변수 `PRETENDARD_FONT` 에 Pretendard 파일(`PretendardVariable.woff2`) 경로를 주면 쓰고, 없으면 시스템 글꼴(Apple SD Gothic Neo)로 합성한다.
