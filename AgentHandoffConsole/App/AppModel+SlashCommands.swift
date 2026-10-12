import Foundation

/// 입력창 "/" 목록의 앱 쪽: 키 정하기 · 받아 두기 · 보낼 때 Codex 스킬 찾기. 판정 · 해석 · CLI 조회는 `Agents/SlashCommands.swift`.
/// 목록은 입력창에서 "/" 를 칠 때 없거나 `SlashCommands.staleAfter` 가 지났으면 받는다 (오래된 목록은 받는 동안에도 보인다). 그 폴더에서
/// Claude 실행이 돌면 그 실행의 초기화 응답으로도 새로 받는다(`receiveSlashCommands` — 따로 띄우지 않는다). 받은 목록은 설정
/// `slash_commands` 에 남겨 앱을 다시 켜도 첫 "/" 에서 바로 보인다 (CLI 를 띄우는 0.3 ~ 1초를 기다리지 않게).
extension AppModel {
    /// 그 대화 · 에이전트의 목록 키. 목록이 없는 에이전트(Antigravity) · 폴더가 없는 대화면 nil.
    func slashCommandKey(thread: ConversationThread, provider: AgentProvider) -> SlashCommandKey? {
        guard provider != .gemini, let project = folderProject(for: thread) else { return nil }
        return SlashCommandKey(provider: provider, accountID: thread.scope(for: provider).accountID, folder: project.path)
    }

    /// 없거나 오래됐으면 받는다 (도는 조회가 있으면 그것을 기다린다). 오래된 목록은 받는 동안에도 그대로 보인다.
    func refreshSlashCommandsIfStale(_ key: SlashCommandKey, now: Date = Date()) async {
        if let fetched = slashCommandLists[key]?.fetchedAt, now.timeIntervalSince(fetched) < SlashCommands.staleAfter { return }
        await refreshSlashCommands(key)
    }

    func refreshSlashCommands(_ key: SlashCommandKey) async {
        if let running = slashCommandRefreshes[key] {
            await running.value
            return
        }
        let task = Task { await self.fetchSlashCommands(key) }
        slashCommandRefreshes[key] = task
        loadingSlashCommands.insert(key)
        await task.value
        slashCommandRefreshes[key] = nil
        loadingSlashCommands.remove(key)
    }

    private func fetchSlashCommands(_ key: SlashCommandKey) async {
        var list: SlashCommandList
        if let override = slashCommandFetchOverride {
            list = await override(key)
        } else if Self.offlinePreview {
            // 화면 확인용 실행은 CLI 를 부르지 않는다 (넣어 둔 목록이 없으면 빈 목록).
            list = SlashCommandList(fetchedAt: Date())
        } else {
            let status = await environment.checkStatus(key.provider)
            guard let path = status.resolvedPath else {
                slashCommandLists[key] = SlashCommandList(
                    commands: slashCommandLists[key]?.commands ?? [], fetchedAt: Date(),
                    message: status.error ?? "\(key.provider.displayName) CLI 를 찾지 못했습니다.")
                return
            }
            let folder = URL(fileURLWithPath: key.folder)
            switch key.provider {
            case .claude:
                list = await SlashCommandCatalog.fetchClaude(path: path, environment: await environment.childEnvironment(),
                                                             workingDirectory: folder)
            case .codex:
                let home = accounts.accountOrDefault(key.accountID).homePath
                list = await SlashCommandCatalog.fetchCodex(path: path,
                                                            environment: await environment.childEnvironment(codexHome: home),
                                                            workingDirectory: folder)
            case .gemini:
                list = SlashCommandList(fetchedAt: Date())
            }
        }
        // 받지 못했으면 지난 목록을 남긴다 (까닭은 함께 적는다).
        if list.commands.isEmpty, list.message != nil, let previous = slashCommandLists[key]?.commands {
            list.commands = previous
        }
        slashCommandLists[key] = list
        if list.message == nil, !list.commands.isEmpty { saveSlashCommands() }
    }

    /// 실행의 초기화 응답에 온 목록 (`RunCoordinator.slashCommandsHandler`). 빈 목록은 버린다.
    func receiveSlashCommands(_ commands: [SlashCommand], for key: SlashCommandKey) {
        guard !commands.isEmpty else { return }
        if let current = slashCommandLists[key], current.commands == commands, current.message == nil {
            // 같은 목록 — 받은 때만 고친다 (실행마다 다시 저장하지 않는다).
            slashCommandLists[key]?.fetchedAt = Date()
            return
        }
        slashCommandLists[key] = SlashCommandList(commands: commands, fetchedAt: Date())
        saveSlashCommands()
    }

    /// 저장 형식 — 키 · 받은 때 · 목록.
    struct SavedSlashCommands: Codable {
        var key: SlashCommandKey
        var fetchedAt: Date
        var commands: [SlashCommand]
    }

    /// 최근에 받은 목록 `savedSlashCommandLimit` 개만 남긴다 (폴더마다 수십 줄이라 끝없이 쌓지 않게).
    static let savedSlashCommandLimit = 12

    private func saveSlashCommands() {
        let saved = slashCommandLists.compactMap { key, list -> SavedSlashCommands? in
            guard let fetchedAt = list.fetchedAt, !list.commands.isEmpty else { return nil }
            return SavedSlashCommands(key: key, fetchedAt: fetchedAt, commands: list.commands)
        }
        .sorted { $0.fetchedAt > $1.fetchedAt }
        .prefix(Self.savedSlashCommandLimit)
        persistSetting("slash_commands", Self.jsonString(Array(saved)))
    }

    /// 앱을 켤 때 (`loadSettings`). 받은 때도 되살린다 — 오래됐으면 다음 "/" 에서 보이면서 뒤에서 다시 받는다.
    func restoreSlashCommands(_ json: String) {
        guard let data = json.data(using: .utf8),
              let saved = try? JSONDecoder().decode([SavedSlashCommands].self, from: data) else { return }
        for entry in saved where slashCommandLists[entry.key] == nil {
            slashCommandLists[entry.key] = SlashCommandList(commands: entry.commands, fetchedAt: entry.fetchedAt)
        }
    }

    /// 보낼 Codex 글 속 "$이름" 가운데 그 대화 폴더 · 계정의 스킬 (`turn/start` 에 스킬 입력으로 덧붙인다). "$" 가 있는데
    /// 받아 둔 목록이 없으면 먼저 받는다 — 목록을 열지 않고 "$pdf …" 를 쳐 보낸 것도 스킬로 가게.
    func codexSkillMentions(in prompt: String, thread: ConversationThread) async -> [SkillMention] {
        guard SlashCommands.mayMentionCodexSkill(prompt),
              let key = slashCommandKey(thread: thread, provider: .codex) else { return [] }
        if slashCommandLists[key]?.fetchedAt == nil { await refreshSlashCommands(key) }
        return SlashCommands.codexMentions(in: prompt, skills: slashCommandLists[key]?.commands ?? [])
    }
}

#if DEBUG
extension AppModel {
    /// 화면 확인용 (`-preview.slash YES`, AHC_OFFLINE=1): CLI 대신 실제와 비슷한 목록을 준다 (2026-10-07 claude 2.1.292 · codex 0.160.1 에서
    /// 받은 것의 일부, 설명은 줄였다).
    func previewSlashCommands() {
        slashCommandFetchOverride = { key in
            let claude: [SlashCommand] = [
                SlashCommand(name: "code-review", description: "Review the current diff, or a PR number/branch/path target, for correctness bugs",
                             argumentHint: "[target] [level]"),
                SlashCommand(name: "simplify", description: "Review the changed code for reuse, simplification, efficiency, and altitude cleanups"),
                SlashCommand(name: "verify", description: "Verify that a code change actually does what it's supposed to by exercising it end-to-end"),
                SlashCommand(name: "run", description: "Launch and drive this project's app to see a change working"),
                SlashCommand(name: "loop", description: "Run a prompt or slash command on a recurring interval", argumentHint: "[interval] [prompt]",
                             aliases: ["proactive"]),
                SlashCommand(name: "compact", description: "Free up context by summarizing the conversation so far",
                             argumentHint: "<optional custom summarization instructions>"),
                SlashCommand(name: "context", description: "Show current context usage"),
                SlashCommand(name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation"),
                SlashCommand(name: "security-review", description: "Complete a security review of the pending changes on the current branch"),
                SlashCommand(name: "usage", description: "Show session cost, plan usage, and what's contributing to your limits",
                             aliases: ["cost", "stats"]),
                SlashCommand(name: "anthropic-skills:pdf", description: "Use this skill whenever the user wants to do anything with PDF files"),
                SlashCommand(name: "docx", description: "Use this skill whenever the user wants to create, read, edit, or manipulate Word documents"),
            ]
            let codex: [SlashCommand] = [
                SlashCommand(name: "documents:documents", description: "Create and edit Word and Google Docs files", path: "/preview/documents/SKILL.md"),
                SlashCommand(name: "pdf:pdf", description: "Read, create, render, and verify PDF files", path: "/preview/pdf/SKILL.md"),
                SlashCommand(name: "lecture-note", description: "강의 노트를 정리합니다", path: "/preview/lecture-note/SKILL.md"),
            ]
            return SlashCommandList(commands: key.provider == .codex ? codex : claude, fetchedAt: Date())
        }
    }
}
#endif
