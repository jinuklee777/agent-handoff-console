import AppKit
import SwiftUI

/// 파일 탭. 이름·내용으로 찾고, 이 대화에서 에이전트가 건드린 파일에 그 에이전트 로고를 붙인다.
/// 읽기 전용이다. 파일을 고르면 아래 절반에 미리보기(`FilePreviewView` — Markdown · 글 · 코드 · 그림)가 뜨고, 두 번 누르거나 ↵ 로
/// 열면 macOS 기본 앱으로 연다 — 실행될 수 있는 파일은 열지 않고 Finder 에서 보인다 (`FileOpenRule`).
/// 펼친 폴더 · 찾는 글자는 폴더마다 기억한다 (`AppModel.filesTreeMemory` — 탭을 오가도 남는다). git 상태를 다시 읽으면(실행이
/// 파일을 바꿈 · 앱 활성화 · 다시 읽기) 펼친 폴더를 다시 읽어 새 파일 · 지운 파일이 보인다 (chg-4).
struct FilesPane: View {
    @Environment(AppModel.self) private var model

    enum SearchMode: String, CaseIterable, Identifiable {
        case name = "이름", content = "내용"
        var id: String { rawValue }
    }

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var mode: SearchMode = .name
    @State private var changedOnly = false
    @State private var expanded: Set<String> = []
    @State private var children: [String: [FileNode]] = [:]
    @State private var selectedPath: String?
    @State private var hoveredPath: String?
    @State private var allFiles: [String]?
    @State private var contentMatches: [GitWorkspace.ContentMatch] = []
    @State private var contentError: String?
    @State private var searching = false
    @State private var touched: [String: Set<AgentProvider>] = [:]
    /// 기억을 되살리는 중 (그동안의 상태 변화를 다시 기억하지 않는다).
    @State private var restoring = false
    /// 미리보기를 닫았다 — 다른 파일을 고르면 다시 뜬다.
    @State private var previewClosed = false

    private var root: URL? { model.workspace.projectURL }
    /// 내용 찾기는 git 저장소에서만 된다 (`git grep`). 저장소가 아니면 고르지 못하게 한다 (chg-23).
    private var contentSearchAvailable: Bool { model.workspace.git?.isRepository != false }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    listContent
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            // 고른 파일의 미리보기 — 목록과 높이를 반씩 나눈다.
            if let file = previewFile, let root {
                Divider()
                FilePreviewView(url: root.appendingPathComponent(file), path: file,
                                openInDefaultApp: { open(file, confirmRisky: true) },
                                close: { previewClosed = true })
                    .frame(maxHeight: .infinity)
                    .id(file)
            }
            legend
        }
        .onChange(of: selectedPath) { _, _ in previewClosed = false }
        .task(id: model.workspace.projectPath) { await openFolder() }
        .task(id: touchedKey) { recomputeTouched() }
        .task(id: searchKey) { await runSearch() }
        // git 상태를 다시 읽었다 = 파일이 바뀌었을 수 있다 — 펼친 폴더 · 이름 찾기 목록을 다시 읽는다 (chg-4).
        .onChange(of: model.workspace.git?.fetchedAt) { _, _ in
            Task { await reloadAfterChange() }
        }
        .onChange(of: memory) { _, new in
            guard !restoring, let path = model.workspace.projectPath else { return }
            model.filesTreeMemory[path] = new
        }
        .onChange(of: contentSearchAvailable) { _, available in
            if !available, mode == .content { mode = .name }
        }
        .onReceive(NotificationCenter.default.publisher(for: .handoffConsoleFocusFileSearch)) { _ in
            searchFocused = true
        }
    }

    /// 미리보기할 파일 — 고른 것이 (폴더가 아닌) 있는 파일이고 미리보기를 닫지 않았을 때.
    private var previewFile: String? {
        guard !previewClosed, let selectedPath, let root else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(selectedPath).path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return selectedPath
    }

    /// 폴더마다 기억할 화면 상태.
    private var memory: FilesTreeMemory {
        FilesTreeMemory(expanded: expanded, query: query, mode: mode.rawValue, changedOnly: changedOnly,
                        selectedPath: selectedPath)
    }

    // MARK: 머리줄 · 조작

    private var header: some View {
        InspectorHeader {
            Text(model.selectedProject?.name ?? root?.lastPathComponent ?? "")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(Fmt.abbreviatedPath(root?.path ?? ""))
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.slate2)
                .lineLimit(1)
                .truncationMode(.head)
        } trailing: {
            IconButton(systemName: "arrow.clockwise", size: 11.5, help: "다시 읽기",
                       spinning: model.workspace.isRefreshingGit) {
                Task {
                    await model.workspace.refreshGit()
                    await resetTree(keepExpanded: true)
                }
            }
            Menu {
                if let root {
                    Button("Finder 에서 열기") { NSWorkspace.shared.open(root) }
                    Button("터미널에서 열기") { TerminalLauncher.open(root) }
                    Button("경로 복사") { copy(root.path) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.slate2)
                    .frame(width: 21, height: 21).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("파일 탭 메뉴 — Finder · 터미널 · 경로 복사")
            .accessibilityLabel("파일 탭 메뉴")
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            SearchField(placeholder: mode == .name ? "파일 찾기 (⌘P)" : "내용 찾기 (⌘P)", text: $query,
                        plain: true, focus: $searchFocused)
            if contentSearchAvailable {
                PillSegmented(options: SearchMode.allCases, selection: $mode, stretch: true,
                              background: Theme.well) { value, selected in
                    PillText(text: value.rawValue, selected: selected)
                }
            } else {
                // 내용 찾기는 git grep 이라 저장소에서만 된다 — 고를 수 없는 단추를 두지 않고 까닭을 적는다 (chg-23).
                Text("Git 저장소가 아니라 이름으로만 찾습니다")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
            HStack(spacing: 8) {
                Toggle("이 대화에서 바뀐 파일만", isOn: $changedOnly)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.ink)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                Spacer()
                Text("\(touched.count)")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
                    .help("이 대화에서 에이전트가 편집한 것으로 관찰된 파일 수")
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: 목록

    @ViewBuilder
    private var listContent: some View {
        // Git 상태 표는 한 번만 만들어 모든 행이 나눠 쓴다.
        let status = self.status
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            if mode == .name || !contentSearchAvailable { nameResults(status) } else { contentResults }
        } else if changedOnly {
            changedList(status)
        } else {
            ForEach(treeRows, id: \.node.id) { row in
                treeRow(row.node, depth: row.depth, status: status)
            }
            if children[""]?.isEmpty == true {
                QuietEmptyState(systemImage: "folder", title: "빈 폴더입니다")
            }
        }
    }

    private struct TreeRow {
        let node: FileNode
        let depth: Int
    }

    private var treeRows: [TreeRow] {
        var rows: [TreeRow] = []
        func walk(_ path: String, depth: Int) {
            for node in children[path] ?? [] {
                rows.append(TreeRow(node: node, depth: depth))
                if node.isDirectory, expanded.contains(node.path) {
                    walk(node.path, depth: depth + 1)
                }
                if rows.count > 4000 { return }
            }
        }
        walk("", depth: 0)
        return rows
    }

    /// 트리 한 줄 — 단추라 키보드(Tab · space)와 VoiceOver 로도 고르고 펼친다. 폴더는 → · ← 로 펼치고 접고, 파일은 ↵ 로 연다 (txt-20).
    private func treeRow(_ node: FileNode, depth: Int, status: StatusMap) -> some View {
        let isOpen = expanded.contains(node.path)
        let indent = 6 + CGFloat(depth) * 16 + (node.isDirectory ? 0 : 16)
        let code = node.isDirectory ? nil : status.byPath[node.path]
        return Button {
            selectedPath = node.path
            if node.isDirectory { toggle(node.path) }
        } label: {
            FileRow(node: node, isOpen: isOpen, indent: indent,
                    code: code,
                    dirMark: node.isDirectory ? status.dirMarks[node.path] : nil,
                    providers: node.isDirectory ? [] : touched[node.path] ?? [],
                    selected: selectedPath == node.path,
                    hovered: hoveredPath == node.path,
                    detail: nil)
        }
        .buttonStyle(.plain)
        .onHover { inside in hoveredPath = inside ? node.path : (hoveredPath == node.path ? nil : hoveredPath) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !node.isDirectory { open(node.path) }
        })
        .onKeyPress(.rightArrow) {
            guard node.isDirectory, !isOpen else { return .ignored }
            toggle(node.path)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard node.isDirectory, isOpen else { return .ignored }
            toggle(node.path)
            return .handled
        }
        .onKeyPress(.return) {
            guard !node.isDirectory else { return .ignored }
            open(node.path)
            return .handled
        }
        .accessibilityLabel(node.isDirectory ? "\(node.name) 폴더" : node.name)
        .accessibilityValue(node.isDirectory ? (isOpen ? "펼침" : "접힘") : (code.map(GitCode.name) ?? ""))
        .accessibilityAddTraits(selectedPath == node.path ? .isSelected : [])
        .accessibilityAction(named: node.isDirectory ? (isOpen ? "접기" : "펼치기") : "열기") {
            if node.isDirectory { toggle(node.path) } else { open(node.path) }
        }
        .contextMenu { fileMenu(node.path, isDirectory: node.isDirectory) }
    }

    @ViewBuilder
    private func nameResults(_ status: StatusMap) -> some View {
        if let allFiles {
            let q = query.trimmingCharacters(in: .whitespaces)
            let byName = allFiles.filter { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(q) }
            let byPath = allFiles.filter {
                !($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(q)
                    && $0.localizedCaseInsensitiveContains(q)
            }
            let results = Array((byName + byPath).prefix(300))
            if results.isEmpty {
                QuietEmptyState(systemImage: "magnifyingglass", title: "일치하는 파일이 없습니다")
            }
            ForEach(results, id: \.self) { path in flatRow(path, status: status) }
            if byName.count + byPath.count > results.count {
                Text("결과가 많아 앞의 \(results.count)개만 보여줍니다.")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2).padding(8)
            }
        } else {
            searchingRow
        }
    }

    @ViewBuilder
    private var contentResults: some View {
        if searching {
            searchingRow
        } else if let contentError {
            QuietEmptyState(systemImage: "text.magnifyingglass", title: "내용 검색을 할 수 없습니다",
                            detail: contentError)
        } else if contentMatches.isEmpty {
            QuietEmptyState(systemImage: "text.magnifyingglass", title: "일치하는 내용이 없습니다")
        } else {
            ForEach(contentMatches) { match in
                Button {
                    selectedPath = match.path
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text((match.path as NSString).lastPathComponent)
                                .font(Theme.ui(.callout)).foregroundStyle(Theme.ink2).lineLimit(1)
                            Text(":\(match.line)").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                            Spacer()
                            Text((match.path as NSString).deletingLastPathComponent)
                                .font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Text(match.text)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.slate)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { open(match.path) })
                .onKeyPress(.return) {
                    open(match.path)
                    return .handled
                }
                .accessibilityLabel("\((match.path as NSString).lastPathComponent) \(match.line)번째 줄")
                .accessibilityValue(match.text)
                .accessibilityAction(named: "열기") { open(match.path) }
                .contextMenu { fileMenu(match.path, isDirectory: false) }
            }
        }
    }

    @ViewBuilder
    private func changedList(_ status: StatusMap) -> some View {
        let paths = touched.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if paths.isEmpty {
            QuietEmptyState(systemImage: "doc.badge.clock", title: "편집 기록이 없습니다",
                            detail: "이 대화에서 에이전트가 편집 도구로 바꾼 파일이 없습니다. "
                                + "명령으로 바꾼 파일은 변경사항 탭에서 확인하세요.")
        }
        ForEach(paths, id: \.self) { path in flatRow(path, status: status) }
    }

    private func flatRow(_ path: String, status: StatusMap) -> some View {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let code = status.byPath[path]
        return Button {
            selectedPath = path
        } label: {
            FileRow(node: FileNode(path: path, name: name, isDirectory: false), isOpen: false, indent: 8,
                    code: code, dirMark: nil, providers: touched[path] ?? [],
                    selected: selectedPath == path, hovered: hoveredPath == path,
                    detail: dir.isEmpty ? nil : dir)
        }
        .buttonStyle(.plain)
        .onHover { inside in hoveredPath = inside ? path : (hoveredPath == path ? nil : hoveredPath) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(path) })
        .onKeyPress(.return) {
            open(path)
            return .handled
        }
        .accessibilityLabel(name)
        .accessibilityValue([code.map(GitCode.name), dir.isEmpty ? nil : dir].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selectedPath == path ? .isSelected : [])
        .accessibilityAction(named: "열기") { open(path) }
        .contextMenu { fileMenu(path, isDirectory: false) }
    }

    private var searchingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("찾는 중…").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
        }
        .padding(12)
    }

    /// 범례 — 에이전트 로고는 `AgentProvider.allCases`, 상태 글자는 `GitCode` 의 이름에서 만든다 (빠지는 것이 없게 — txt-28).
    /// 줄이 넘치면 글자만 남기고 이름은 도움말로.
    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(AgentProvider.allCases) { provider in
                    BrandMark(provider: provider, size: 10)
                }
                Text("에이전트가 편집").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            }
            .help(AgentProvider.allCases.map { "\($0.displayName) 로고 = \($0.displayName) 가 편집한 파일" }.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("에이전트 로고: " + AgentProvider.allCases.map(\.displayName).joined(separator: " · ")
                                + " 가 편집한 파일")
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                ForEach(GitCode.legendCodes, id: \.self) { code in
                    Text(code).foregroundStyle(GitCode.color(code)).fontWeight(.bold)
                }
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.slate2)
            }
            .font(Theme.mono(.caption))
            .help(GitCode.legendCodes.map { "\($0) \(GitCode.name($0))" }.joined(separator: " · "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("상태 글자: " + GitCode.legendCodes.map { "\($0) \(GitCode.name($0))" }.joined(separator: ", "))
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    // MARK: 상태

    /// 저장소 루트 기준 Git 상태를 프로젝트 기준 경로로 옮기고, 변경이 있는 폴더에 점을 찍는다.
    private typealias StatusMap = (byPath: [String: String], dirMarks: [String: Color])

    private var status: StatusMap {
        guard let git = model.workspace.git, git.isRepository else { return ([:], [:]) }
        let prefix = git.projectPrefix.isEmpty ? "" : git.projectPrefix + "/"
        var byPath: [String: String] = [:]
        var marks: [String: Color] = [:]
        for (path, code) in git.codeByPath {
            guard prefix.isEmpty || path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            byPath[relative] = code
            var dir = (relative as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                if code != "??" || marks[dir] == nil {
                    marks[dir] = code == "??" ? Theme.slate2 : Theme.amber
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return (byPath, marks)
    }

    private var touchedKey: String {
        "\(model.selectedThreadID ?? "")|\(model.events.count)"
    }

    private var searchKey: String {
        "\(mode.rawValue)|\(query)|\(model.workspace.projectPath ?? "")"
    }

    private func recomputeTouched() {
        touched = ExecutionParser.touchedFiles(in: model.events, projectPath: model.workspace.projectPath)
    }

    /// 폴더가 바뀌었다 (처음 나타날 때 포함) — 그 폴더의 기억(펼친 폴더 · 찾는 글자)을 되살리고 트리를 읽는다.
    private func openFolder() async {
        guard let path = model.workspace.projectPath else { return }
        restoring = true
        let saved = model.filesTreeMemory[path] ?? FilesTreeMemory()
        expanded = saved.expanded
        query = saved.query
        mode = SearchMode(rawValue: saved.mode) ?? .name
        if !contentSearchAvailable { mode = .name }
        changedOnly = saved.changedOnly
        selectedPath = saved.selectedPath
        #if DEBUG
        // 화면 확인용: `-preview.fileSelect <프로젝트 기준 경로>` — 그 파일을 고른 채로 연다 (미리보기). `AHC_OFFLINE=1` 일 때만.
        if ProcessInfo.processInfo.environment["AHC_OFFLINE"] == "1",
           let preview = UserDefaults.standard.string(forKey: "preview.fileSelect"), !preview.isEmpty {
            selectedPath = preview
        }
        #endif
        allFiles = nil
        contentMatches = []
        contentError = nil
        restoring = false
        await resetTree(keepExpanded: true)
    }

    /// git 상태를 다시 읽은 뒤: 펼친 폴더를 다시 읽고, 이름 찾기 목록을 읽어 두었으면 그것도 새로 (찾는 중인 화면을 비우지 않게
    /// 새 목록이 올 때까지 앞 목록을 둔다).
    private func reloadAfterChange() async {
        await resetTree(keepExpanded: true)
        guard allFiles != nil, let root else { return }
        let env = await model.environment.childEnvironment()
        let files = await GitWorkspace.listFiles(at: root, environment: env)
        guard root == self.root else { return }
        allFiles = files
    }

    private func resetTree(keepExpanded: Bool = false) async {
        guard let root else { return }
        if !keepExpanded {
            expanded = []
            selectedPath = nil
        }
        let paths = [""] + expanded.sorted()
        var loaded: [String: [FileNode]] = [:]
        for path in paths {
            loaded[path] = await Task.detached { FileTree.children(of: path, root: root) }.value
        }
        guard root == self.root else { return }
        // 지워진 폴더는 펼침에서 뺀다 (다시 만들어지면 접힌 채로 보인다). 접힌 폴더 안의 펼침은 그대로 둔다.
        expanded = expanded.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        children = loaded
    }

    /// 펼칠 때마다 그 폴더를 다시 읽는다 (접어 둔 동안 바뀌었을 수 있다 — 앞 내용은 새 내용이 올 때까지 둔다).
    private func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
            return
        }
        expanded.insert(path)
        guard let root else { return }
        Task {
            let nodes = await Task.detached { FileTree.children(of: path, root: root) }.value
            guard root == self.root else { return }
            children[path] = nodes
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let root else { return }
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        let env = await model.environment.childEnvironment()
        switch mode {
        case .name:
            if allFiles == nil {
                let files = await GitWorkspace.listFiles(at: root, environment: env)
                guard !Task.isCancelled else { return }
                allFiles = files
            }
        case .content:
            guard contentSearchAvailable else { return }
            searching = true
            contentError = nil
            let result = await GitWorkspace.grep(q, at: root, environment: env)
            guard !Task.isCancelled else { return }
            searching = false
            switch result {
            case .success(let matches): contentMatches = matches
            case .failure(let error): contentMatches = []; contentError = error.message
            }
        }
    }

    // MARK: 동작

    @ViewBuilder
    private func fileMenu(_ path: String, isDirectory: Bool) -> some View {
        if !isDirectory { Button("기본 앱으로 열기…") { open(path, confirmRisky: true) } }
        Button("Finder 에서 보기") {
            guard let root else { return }
            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)])
        }
        Button("경로 복사") { copy(path) }
    }

    /// 파일 열기. 실행될 수 있는 파일(`FileOpenRule`)은 열지 않고 Finder 에서 보인다 — 두 번 눌러 바로 돌지 않게 (chg-5).
    /// 심볼릭 링크 · 별칭은 따라간 대상으로 판정한다 (`readme.txt -> Helper.app` 은 앱이다). Finder 에서는 링크 자신을 고른다.
    /// 메뉴의 "기본 앱으로 열기…" 는 그런 파일이면 까닭을 보이고 확인받은 뒤에 연다. 파일이 없으면 알린다.
    private func open(_ path: String, confirmRisky: Bool = false) {
        guard let root else { return }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.banner = AppModel.BannerMessage(text: "파일이 없습니다 (지워졌거나 옮겨졌습니다): \(path)", isError: true)
            Task { await reloadAfterChange() }
            return
        }
        let defaultApp: (URL) -> String? = { NSWorkspace.shared.urlForApplication(toOpen: $0)?.lastPathComponent }
        switch FileOpenRule.action(for: url, defaultApp: defaultApp) {
        case .open:
            if !NSWorkspace.shared.open(url) {
                model.banner = AppModel.BannerMessage(text: "이 파일을 열 앱을 찾지 못했습니다: \(path)", isError: true)
            }
        case .reveal(let reason):
            guard confirmRisky else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
            let alert = NSAlert()
            alert.messageText = "이 파일을 기본 앱으로 열까요?"
            // 무엇이 실행될 수 있는지는 까닭이 말한다 — 폴더를 가리키는 링크에 "프로그램이 실행될 수 있습니다" 를 덧붙이지 않게.
            alert.informativeText = reason + "\n\n" + path
            alert.addButton(withTitle: "Finder 에서 보기")
            alert.addButton(withTitle: "열기")
            alert.addButton(withTitle: "취소")
            switch alert.runModal() {
            case .alertFirstButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
            case .alertSecondButtonReturn: NSWorkspace.shared.open(url)
            default: break
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 트리·검색 결과 공용 행 (25pt).
private struct FileRow: View {
    let node: FileNode
    let isOpen: Bool
    let indent: CGFloat
    let code: String?
    let dirMark: Color?
    let providers: Set<AgentProvider>
    let selected: Bool
    let hovered: Bool
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.slate2)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
            }
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Theme.slate : Theme.slate2)
                .frame(width: 14)
            Text(node.name)
                .font(Theme.ui(.callout, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            ForEach(AgentProvider.allCases.filter { providers.contains($0) }) { provider in
                BrandMark(provider: provider, size: 11)
                    .help("이 대화에서 \(provider.displayName) 가 편집함")
            }
            if let code {
                Text(code)
                    .font(Theme.mono(.caption, .bold))
                    .foregroundStyle(GitCode.color(code))
                    .frame(width: 16, alignment: .trailing)
                    .help(GitCode.name(code))
            } else if let dirMark {
                Circle().fill(dirMark).frame(width: 5, height: 5)
                    .help("안에 바뀐 파일이 있음")
            }
        }
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .frame(height: 25)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
            } else if hovered {
                RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Git 상태 코드의 색과 이름. 색만으로 전달하지 않도록 글자와 함께 쓴다.
enum GitCode {
    /// 범례에 쓰는 글자 (파일 탭 아래 — 행에 나올 수 있는 것 전부).
    static let legendCodes = ["M", "A", "D", "R", "U", "??"]

    static func color(_ code: String) -> Color {
        switch code {
        case "M", "T": return Theme.amberText
        case "A", "R", "C": return Theme.emeraldText
        case "D", "U": return Theme.danger
        default: return Theme.slate2
        }
    }

    static func name(_ code: String) -> String {
        switch code {
        case "M": return "수정됨"
        case "T": return "형식 바뀜"
        case "A": return "추가됨"
        case "R": return "이름 바뀜"
        case "C": return "복사됨"
        case "D": return "삭제됨"
        case "U": return "충돌"
        case "??": return "새 파일 (추적 안 됨)"
        default: return code
        }
    }
}
