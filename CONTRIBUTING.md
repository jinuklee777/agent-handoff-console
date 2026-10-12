# Contributing

Thanks for your interest in Agent Handoff Console. Issues and pull requests are welcome in English or Korean. A Korean summary follows the English text (한국어 요약은 아래에 있습니다).

## Before you start

- Start from the code map, [docs/코드구조.md](docs/코드구조.md). It lists each file's responsibilities, the main data flows, where to start for each kind of change and how to verify it. Open only the files your change needs; you don't have to read the whole source tree first. AI coding agents reach the same map through [AGENTS.md](AGENTS.md) (Codex) and [CLAUDE.md](CLAUDE.md) (Claude Code).
- Developer documentation, code comments and commit messages are written in Korean. You may write yours in English.
- For anything larger than a small fix, please open an issue first so we can agree on the approach.
- Report security problems privately as described in [SECURITY.md](SECURITY.md). Do not open a public issue for them.

## What you need

- macOS with **Xcode 26** (macOS 26 SDK). The app itself targets macOS 15 and later.
- The agent CLIs (`claude`, `codex`, `agy`) only to use the app and for the live tests. The offline tests don't call them.
- Python 3 only for the optional tooling in `scripts/` (README images, protocol probes).

## Build

```bash
xcodebuild -project AgentHandoffConsole.xcodeproj -scheme AgentHandoffConsole \
  -configuration Debug -derivedDataPath build/DerivedData.noindex build
```

- Always pass `-derivedDataPath build/DerivedData.noindex`. Copies built into Xcode's default DerivedData show up in Spotlight as duplicate apps.
- The Xcode project uses folder-synchronized groups, so a new Swift file under `AgentHandoffConsole/` joins the app target by itself.
- `./scripts/install-app.sh` is optional. It builds a Release, replaces `~/Applications/AgentHandoffConsole.app` and reopens it. It asks a running copy to quit (as ⌘Q would) and unregisters other built copies from Launch Services. Don't use it to check a build in the middle of your work, because it restarts the app every time.

## Test

```bash
./scripts/build-inttest.sh
./build/inttest/inttest offline
```

- `build-inttest.sh` compiles the app's real non-UI sources together with `scripts/inttest/` into one executable. It runs one compiler process per file, takes 5–10 minutes, and some files need a few GB of memory. **Run only one build at a time**: on a 16 GB Mac, three parallel builds once caused a kernel panic.
- `inttest offline` calls no CLI. A passing run ends with the summary line `합계 N/N 통과` ("total N/N passed"), and failures are listed below it under `실패 항목`. Check that line, not only the exit code.
- Smaller offline groups for quick iterations: `handoffcard` (handoff cards, held messages, continue), `workspace` (Changes tab, git, worktrees, UI source lint), `approvalcards`, `codexswitch` (switching Codex accounts within one session, schema), `overview`, `slash`, `claudeapi`, `titles`, `agylimits`, `orbs`.
- **Live groups call the real CLIs and use your plan's usage**, and some edit files in temporary folders: `all`, `live`, `autohandoff`, `background`, `multirun`, `staleresume`, `releasefix`, `gemini`, `antigravity` and others. Run them only when your change touches how the app talks to a CLI, and say in the pull request which ones you ran.
- When you add a non-UI source file, add it to the source list in `scripts/build-inttest.sh`.
- Don't let a test depend on your Mac's settings. GitHub's macOS runners have Reduce Motion on, `safe.directory = *` in the global git config and no `~/.codex` login. The default Codex account reads `.codex` in your real home, not `$HOME`, so tests that need a logged-in receiver create a temporary account folder with an `auth.json`. To imitate the runner, run `inttest offline` with an empty `HOME` (plus that `.gitconfig`) and an empty `CODEX_HOME`.
- CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on every push to `main` and every pull request. On a `macos-26` runner with Xcode 26.6 it builds the app, builds the harness and runs `inttest offline`. It passes only when the summary line shows every check passed and the total is not below a floor (`MIN_CHECKS`; lower it in the same PR if you remove tests). It also checks that every file in `scripts/inttest/` is in the source list of `build-inttest.sh`.
- Keep test functions small. One async function with hundreds of `await`s once made a single compiler process use about 20 GB.
- When you change how a run flows, add a scenario that drives `RunCoordinator` with the scripted fake adapter (`scripts/inttest/ScriptedAgentAdapter.swift`). The CLI parsers are covered by replays of recorded real sessions (`scripts/probe/*/logs`); add a recording when a CLI's output changes.
- The UI source lint (`scripts/inttest/TypeScaleLintTests.swift`, part of `offline`) enforces a few rules:
  - text sizes come only from the four `Theme` steps;
  - icon-only buttons need an `.accessibilityLabel`;
  - a Korean particle after an English name is separated by a space ("Codex 에게");
  - retired terms must not reappear.
- To look at screens without touching your own data or calling a CLI, use the preview tooling in [scripts/preview/README.md](scripts/preview/README.md). It uses a Debug build with a separate bundle ID, a temporary database and `AHC_OFFLINE=1`.

## Releases

`scripts/make-release.sh` makes the release zip. Run it in a clean, full (not shallow) clone; it clones the current commit into a temporary folder and builds there, so the zip matches the commit exactly and no path from your home folder ends up in the binary. It builds a universal Release (arm64 and x86_64), ad-hoc signed and without the debugger entitlement (`get-task-allow`) that Xcode adds to ad-hoc builds, checks the signature again after unzipping, and writes `build/release.noindex/AgentHandoffConsole-<version>.zip` (the app, `LICENSE` and `THIRD_PARTY_NOTICES.md` in one folder) and `SHA256SUMS.txt`. The version is `MARKETING_VERSION`; the build number is the commit count, as with `install-app.sh`. Attach both files to a draft release targeting the same commit and put the checksum in the notes.

## Pull requests

- Keep one change per pull request, and include only the files it needs: no personal files, build output or generated artifacts unless the PR is about them.
- In the description, cover:
  - what changed and why;
  - how you verified it: paste the `합계 N/N 통과` line and list the live tests you ran or skipped;
  - for UI changes, screenshots (light and dark if colors are involved).
- If you change a file's responsibilities or a data flow, update [docs/코드구조.md](docs/코드구조.md) and the table in [AGENTS.md](AGENTS.md).
- Commit messages have a subject line and a body: the purpose, the main changes, how you verified them and what is still unverified. Don't claim a test you didn't run.
- AI-assisted contributions are welcome, but you are responsible for them. Read the code, run the tests and be ready to explain every change. Credit the tool with a `Co-Authored-By:` trailer naming the tool and the exact model, for example `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` or `Co-Authored-By: Codex (GPT-6 Astra) <noreply@openai.com>`.
- By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).

## Principles the code follows

- **Don't make things up.** What the app cannot determine is shown as unconfirmed. A usage limit that can't be read is "no information", not 0%. A handoff whose delivery is unknown is never re-sent automatically.
- **Decisions live in pure code.** Rules that decide what to show or allow live in plain types without SwiftUI, so the test harness can compile and test them; views only display the result.
- **Safe git writes only.** The app does not force-push, run `reset --hard` or `clean`, or delete branches other than a conversation's own worktree branch when the user chooses so. Git writes wait while an agent runs in that folder.
- **The user's environment stays the user's.** The app never edits shell configuration, and it never decodes or rewrites login tokens. It writes into a CLI's own data in two places only: it copies a conversation's Claude session file when that conversation moves into or out of a worktree, and, to continue a Codex session under another of your accounts, it builds a temporary `CODEX_HOME` for that run (links to the account's files — `auth.json` is linked, not copied) and creates any missing session-record folders in the account folder that holds the session.

---

## 한국어 요약

- 먼저 [코드 구조 지도](docs/코드구조.md)를 읽고, 바꿀 일과 관계있는 파일만 연다. 이슈 · PR 은 한국어 · 영어 모두 받는다. 큰 변경은 이슈로 먼저 의논한다. 보안 문제는 [SECURITY.md](SECURITY.md) 의 비공개 신고로.
- 필요한 것: Xcode 26 (macOS 26 SDK). 앱은 macOS 15 이상에서 돈다. CLI 는 앱을 쓰거나 실제 CLI 시험을 할 때만 필요하다.
- 빌드: `xcodebuild … -derivedDataPath build/DerivedData.noindex build` (위 명령). `./scripts/install-app.sh` 는 선택이다 — 이 Mac 의 설치본을 바꾸고 다른 사본의 등록을 해제한다.
- 시험: `./scripts/build-inttest.sh` → `./build/inttest/inttest offline`. 끝의 "합계 N/N 통과" 줄을 본다. 시험 실행 파일 빌드는 5~10분 걸리고 메모리를 많이 쓰므로 **동시에 여러 개 돌리지 않는다** (16GB 맥에서 셋이 겹쳐 커널 패닉이 난 적이 있다). 실제 CLI 를 부르는 묶음은 구독 사용량을 쓰니 필요할 때만 돌리고 PR 에 적는다.
- CI(`.github/workflows/ci.yml`): `main` 에 올릴 때와 PR 마다 `macos-26` 러너(Xcode 26.6)에서 앱 빌드 → 시험 실행 파일 빌드 → `inttest offline`. "합계 N/N 통과" 이고 확인 수가 하한(`MIN_CHECKS`) 이상이어야 통과한다 — 시험을 지우면 같은 PR 에서 하한을 낮춘다.
- 릴리스 zip: `scripts/make-release.sh` — 깨끗한 전체 클론에서 실행하면 지금 커밋을 임시 폴더에 새로 클론해 유니버설 Release(ad-hoc 서명)를 빌드하고 `build/release.noindex/` 에 zip(앱 · LICENSE · THIRD_PARTY_NOTICES.md)과 `SHA256SUMS.txt` 를 만든다. 빌드 번호는 커밋 수.
- 시험은 이 Mac 의 설정에 기대지 않는다 — CI 러너는 동작 줄이기가 켜져 있고, git 전역 설정에 `safe.directory = *` 가 있고, `~/.codex` 로그인이 없다.
- 새 비 UI 파일은 `scripts/build-inttest.sh` 목록에 더한다. 실행 흐름을 바꾸면 가짜 어댑터 시나리오를 더한다. 책임 · 흐름을 바꾸면 코드 구조 지도와 AGENTS.md 의 표를 고친다.
- 커밋은 제목만 쓰지 않는다 — 목적 · 바꾼 것 · 확인한 것 · 남은 것. 돌리지 않은 시험을 통과했다고 쓰지 않는다. AI 로 만든 기여도 받되, 내용을 설명할 수 있어야 하고 `Co-Authored-By` 에 도구와 정확한 모델명을 적는다.
- 기여한 코드는 [MIT 라이선스](LICENSE)로 공개된다.
