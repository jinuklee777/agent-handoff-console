# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

<!-- Draft for v0.1.0: confirm the date and add any last-minute changes on release day. -->

## [0.1.0] - 2026-10-11

The first public release. The user interface is in Korean; an English UI is planned for v0.2. Development before this release happened in a private repository, so its history is not included here.

### Added

- **Handoff between agents.** Hand a conversation from Claude Code, Codex or Antigravity to another agent through a handoff card at the end of the conversation. The card shows the receiver, what the app confirmed about it, a picker for the receiving model, and a summary of the handoff document; you review it, add a note, and send. The document is built by rules from the conversation record and a git snapshot, marks unconfirmed facts as such, and masks secrets on a best-effort basis. Messages typed while a card is open are held for the receiver. Each handoff is tracked as delivered, failed or unknown, and unknown deliveries are never re-sent automatically.
- **Automatic handoff** (off by default). After a run stops at a usage limit, the app checks the receivers in your priority order and counts down before handing off, or shows a review card explaining what blocked it.
- **Continue suggestions** above the composer when the current agent's 5-hour window passes 75% or its weekly window passes 90%.
- **Optional Gemini tidying** of handoff documents through the Antigravity CLI, with citations and test results checked before use.
- **Several agents at once.** One run per conversation, runs in parallel across conversations, a split view with 1, 2 or 4 panes, an Overview of everything running or waiting (⌃⌘0), a "needs response" chip, menu bar status, a Dock badge and notifications.
- **Usage limits** read through each CLI and shown in the toolbar, menu bar, Overview and handoff card: Claude, every Codex account, and Antigravity when a project allows it (`agy -p /usage`, per model group; display only in this release). The menu bar's list can be trimmed per account and window (Settings › General).
- **Changes tab**: per-run changed files, diffs (unified and side by side), staging by checkbox, commit, branches, fetch, pull and push with confirmation.
- **Per-conversation git worktrees** with merge-back safety checks; Files (with an in-app preview of Markdown, text, code and images), Pull Request (read-only, via `gh`) and Terminal tabs.
- **Sub-agents and background work.** Claude background agents, workflows and shells, and Codex sub-agents, are tracked to the end of the run, with an Agents tab.
- **Approval and question cards** with warnings for irreversible commands, deny reasons passed back to Claude, and optional per-conversation auto-approve, which new conversations can start with (off by default).
- **Several Codex accounts, one session.** Switch a conversation to another of your Codex accounts from the agent chip, the limit line, a continue suggestion or an automatic countdown; its Codex session continues under that account's sign-in and limits, without a handoff. The database moves to schema v10 (one Codex session per conversation).
- **Claude on API credits**: a per-conversation switch that runs Claude with an API key kept in the Keychain, and "Continue on API credits" in the same session after a subscription limit.
- Per-conversation models and reasoning effort from the CLIs' own lists; per-turn time, new tokens and API-equivalent cost; the `/` command and skill list; image attachments; a message queue; find in conversation; automatic conversation titles.
- First-run checklist, import of existing Claude Code and Codex sessions, and agent records.
- Experimental, off by default: automatic task orchestration (plan, assign, run one task at a time, verify).

### Fixed

- Deleting a conversation or removing a project deletes the attached image files that only that conversation used, and removing an image from the composer before sending deletes its file. Files still used by other conversations, queued messages or composer drafts are kept, and nothing outside the app's `attachments/` folder is touched.
- Replay fixtures omit opaque thinking signatures, the bundled skill reference and the names of claude.ai connectors; CI checks these exclusions.
- The test harness and the README-image seed now build for the host architecture instead of always arm64 (not yet tested on Intel Macs).

### Security

- Git commands the app runs never start a filesystem monitor program set by the repository. The app's own automatic read-only Git checks (the changes list, the before/after-run comparison, the handoff snapshot and fingerprint, worktree status, orchestration review) also don't run filter programs (clean, smudge, process), textconv or external diff drivers that a repository defines in its own Git config, don't write the index (which could run a `post-index-change` hook), skip commit-signature checks and don't start Git inside submodules. Drivers from your global or system Git config, such as Git LFS, still run, unless the repository's own config adds a Git LFS extension (`lfs.extension.*`) that Git LFS would run; then those reads skip Git LFS too. With Git 2.26–2.30, which ignores settings passed in `GIT_CONFIG_COUNT`, the app passes the same overrides through `GIT_CONFIG_PARAMETERS`. Git actions you start yourself (stage, commit, switch branch, pull, merge, creating or removing a worktree) use the repository's configuration as `git` would.
- Approval cards break a command at every line terminator (CR, CRLF, U+0085, U+2028, U+2029, vertical tab, form feed) and show control, bidi-override and zero-width characters as markers such as ␍ or ⟨U+202E⟩, so a command can't hide its tail; "명령 복사" (copy command) still copies the original. The irreversible-command check reads those breaks too and flags running a download: piping it into a shell or interpreter (`curl … | sh`, `curl … | python3`), a shell command string that is a download (`bash -c "$(curl …)"`, `eval "$(curl …)"`) and process substitution (`bash <(curl …)`, `source <(curl …)`). The Overview leaves multi-line, very long or hidden-character commands to the conversation. File paths, targets and field values in approval cards and the Overview also show those markers, and the Overview leaves a request whose path hides characters to the conversation.
- The Files tab judges a symbolic link or Finder alias by what it points to: a link such as `readme.txt -> Helper.app`, or one to a script, executable, package or folder, is shown in Finder instead of opened. ⌘-clicking a hyperlink (OSC 8) in the embedded terminal follows the rules for links in messages: web addresses open, files are shown in Finder without running, and other URL schemes ask first.
- macOS notifications mask secrets such as API keys and passwords in their title and body, for example in Codex command approvals.
- The shell credential setting also covers Codex, Gemini and Google API keys and the Claude Code OAuth token.

### Known limitations

- Korean UI only; handoff documents are written in Korean.
- Not signed with a Developer ID, not notarized, and no automatic updates.
- Depends on the CLIs' structured protocols; tested with Claude Code 2.1.266–2.1.292, Codex CLI 0.153–0.160 and Antigravity CLI 1.2.1–1.3.2, and the live CLI tests also pass with Claude Code 2.1.295, Codex CLI 0.162.0 and Antigravity CLI 1.3.3.
- The changes list and handoff documents show a submodule only when its checked-out commit changes; uncommitted edits inside a submodule are not listed.
- If a repository's own `.git/config` defines a content filter (for example nbstripout or git-crypt set up per repository), the app's automatic reads skip it, so a filtered file can show as changed until Git refreshes its index (for example after `git status` in a terminal). The same applies to Git LFS files when the repository's own config adds a Git LFS extension.
- See "Known limitations" in [README.md](README.md) for the full list.

[0.1.0]: https://github.com/jinuklee777/agent-handoff-console/releases/tag/v0.1.0
