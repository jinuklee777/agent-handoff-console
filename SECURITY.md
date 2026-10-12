# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Report it privately through GitHub's private vulnerability reporting:

1. Open the repository's **Security** tab and choose **Report a vulnerability**, or go straight to <https://github.com/jinuklee777/agent-handoff-console/security/advisories/new>.
2. Describe the problem, its impact, and the steps to reproduce it.
3. Include the app version (Settings › About › 버전 복사 copies the app and macOS versions) and the versions of the agent CLIs involved (`claude --version`, `codex --version`, `agy --version`).

English or Korean is fine. Agent Handoff Console is a personal project maintained in spare time. You can expect an acknowledgement within about a week, and a fix or mitigation as soon as is practical. Please allow reasonable time for a fix before you disclose the problem publicly. Reporters are credited in the advisory unless they prefer otherwise.

## Supported versions

Only the latest release receives security fixes.

## What is in scope

Agent Handoff Console starts AI coding agents that read, write and run code in your folders with your user account's permissions, and it passes text between them. The app is not sandboxed. These reports are especially welcome:

- **Approval bypass**: an action that should wait for your approval runs without it, or an approval card shows something other than what actually runs.
- **Data going where the documentation says it doesn't**: for example a Claude API key leaving the Keychain, shell API keys being passed to a CLI with the setting off, or content reaching a provider you did not choose.
- **Injection**: commands or arguments injected through file names, branch names, messages, handoff documents or CLI output.
- **Unsafe opening**: links or files from agent output, the Files tab or the embedded terminal that the app opens or executes without the confirmation it promises.
- **Destructive git operations**: data lost through a git operation the app performs beyond what you confirmed.
- **Repository-configured programs**: a program defined by a repository's own Git configuration (filesystem monitor, filter or diff drivers, Git LFS extensions, hooks) running during the app's automatic read-only Git checks. Git actions you start yourself (stage, commit, switch branch, pull, merge, creating or removing a worktree) use the repository's configuration as `git` would.
- **Handoff integrity**: a handoff sent twice, sent to the wrong receiver, or sent without the confirmation the interface shows.

## What is out of scope

- How the agent CLIs (Claude Code, Codex, Antigravity) and their models behave on their own. Please report that to the respective vendor. If the app makes their behaviour less safe, it is in scope.
- Antigravity running without approval prompts. This is documented: the CLI can't ask for permission headlessly, so the app runs it with `--dangerously-skip-permissions`. It is off by default and must be allowed per project.
- Secrets that the best-effort masking in handoff documents misses. Masking is a safety net, not a guarantee; improvements to it are welcome as regular issues or pull requests.
- Gatekeeper warnings caused by the app not being notarized.
- Attacks that require control of your user account or your Mac.
