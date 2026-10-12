import SwiftUI

/// Claude Code · Codex 기록 가져오기. 열리면 이 Mac 의 세션 파일을 훑어 폴더별로 보이고, 자동 선별된 폴더가 체크된 채 시작한다
/// (모두 해제 · 추천만 · 모두 선택으로 바꾼다 — onb-8). 가져오는 중에는 [멈추기] 로 세션 단위로 끊는다 — 그때까지 가져온 것은 남는다.
/// 가져오기는 `SessionImportService` — 같은 CLI 세션은 두 번 들어가지 않는다.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case scanning, ready, importing(String), done(SessionImportResult) }
    @State private var phase: Phase = .scanning
    @State private var folders: [ImportFolder] = []
    @State private var selected: Set<String> = []
    @State private var showAll = false
    /// 훑은 세션 파일 수 (onb-18 — 큰 기록에서 스피너만 돌지 않게).
    @State private var scanCounter = ImportScanCounter()
    /// 가져오기 작업 — [멈추기] 가 취소한다.
    @State private var importTask: Task<Void, Never>?
    @State private var stopping = false

    private var visibleFolders: [ImportFolder] {
        showAll ? folders : folders.filter { $0.recommended || selected.contains($0.id) }
    }
    private var selectedFolders: [ImportFolder] { folders.filter { selected.contains($0.id) } }
    private var selectedSessions: Int { selectedFolders.reduce(0) { $0 + $1.sessions.count } }
    private var recommendedIDs: Set<String> { Set(folders.filter(\.recommended).map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hair).frame(height: 1)
            content
            Rectangle().fill(Theme.hair).frame(height: 1)
            footer
        }
        .frame(width: 600, height: 520)
        .background(Theme.paper)
        .task { await scan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude Code · Codex 기록 가져오기").font(Theme.ui(.body, .semibold)).foregroundStyle(Theme.ink)
            Text("작업했던 폴더를 프로젝트로, 세션을 대화로 옮깁니다. 대화 전문이 들어오고 다음 메시지는 그 CLI 세션을 이어갑니다.")
                .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("~/.claude/projects 와 ~/.codex/sessions 를 읽는 중…").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                if scanCounter.total > 0 {
                    Text("세션 파일 \(scanCounter.done) / \(scanCounter.total)")
                        .font(Theme.digits(.caption)).foregroundStyle(Theme.slate2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .importing:
            VStack(spacing: 0) {
                selectionBar
                Rectangle().fill(Theme.hairSoft).frame(height: 1)
                list
            }
        case .done(let result):
            VStack(alignment: .leading, spacing: 8) {
                Text(result.cancelled ? "가져오기를 멈췄습니다" : "가져왔습니다")
                    .font(Theme.ui(.body, .semibold)).foregroundStyle(Theme.ink)
                if result.cancelled {
                    Text("멈추기 전까지 가져온 프로젝트 · 대화는 그대로 남았습니다. 다시 가져오면 이미 있는 세션은 건너뜁니다.")
                        .font(Theme.ui(.callout)).foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("프로젝트 \(result.projectsAdded)개 등록 · 대화 \(result.threadsAdded)개 생성 · 이미 있던 세션 \(result.skippedExisting)개 · 대화 없는 세션 \(result.skippedEmpty)개 건너뜀")
                    .font(Theme.ui(.callout)).foregroundStyle(Theme.ink2)
                if !result.failures.isEmpty {
                    Text("실패 \(result.failures.count)건").font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.danger).padding(.top, 6)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(result.failures, id: \.self) { Text($0).font(Theme.mono(.caption)).foregroundStyle(Theme.slate).textSelection(.enabled) }
                        }
                    }
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 목록 위 한 줄: 고른 수와 한 번에 고르기 (추천 폴더가 수십 개여도 하나하나 풀지 않게 — onb-8).
    private var selectionBar: some View {
        let importing: Bool = { if case .importing = phase { return true }; return false }()
        let selectable: Set<String> = Set(visibleFolders.filter(\.exists).map(\.id))
        return HStack(spacing: 12) {
            Text("폴더 \(selectedFolders.count)개 고름 · 추천 \(recommendedIDs.count)개")
                .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            Spacer(minLength: 8)
            Button("모두 선택") { selected.formUnion(selectable) }
                .disabled(importing || selectable.isSubset(of: selected))
            Button("추천만") { selected = recommendedIDs }
                .disabled(importing || selected == recommendedIDs)
            Button("모두 해제") { selected.removeAll() }
                .disabled(importing || selected.isEmpty)
        }
        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption, .medium)))
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(visibleFolders) { folder in row(folder) }
                if !showAll {
                    let hidden = folders.count - visibleFolders.count
                    if hidden > 0 {
                        Button("선별에서 빠진 폴더 \(hidden)개 보기 (임시 폴더 · Codex 스크래치 · 지워진 폴더 · 세션 1개)") { showAll = true }
                            .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.ui(.caption)))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                if folders.isEmpty {
                    Text("가져올 세션 기록이 없습니다.").font(Theme.ui(.callout)).foregroundStyle(Theme.slate2).padding(18)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func row(_ folder: ImportFolder) -> some View {
        let importing: Bool = { if case .importing = phase { return true }; return false }()
        return Toggle(isOn: Binding(get: { selected.contains(folder.id) },
                                    set: { on in if on { selected.insert(folder.id) } else { selected.remove(folder.id) } })) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(folder.name).font(Theme.ui(.callout, .medium)).foregroundStyle(folder.exists ? Theme.ink : Theme.slate2).lineLimit(1)
                        if !folder.exists { Text("폴더 없음").font(Theme.ui(.caption)).foregroundStyle(Theme.amberText) }
                        if folder.isGitRepository { Text("git").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2) }
                    }
                    Text(Fmt.abbreviatedPath(folder.path)).font(Theme.mono(.caption)).foregroundStyle(Theme.slate2).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if folder.claudeCount > 0 { count(.claude, folder.claudeCount) }
                    if folder.codexCount > 0 { count(.codex, folder.codexCount) }
                }
                Text(Fmt.dateTime.string(from: folder.updatedAt)).font(Theme.ui(.caption)).foregroundStyle(Theme.slate2).frame(width: 84, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(importing || !folder.exists)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected.contains(folder.id) ? Theme.wellSoft : .clear))
        .help(folder.path)
    }

    private func count(_ provider: AgentProvider, _ n: Int) -> some View {
        HStack(spacing: 4) {
            BrandMark(provider: provider, size: 10)
            Text("\(n)").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .ready:
                Text("폴더 \(selectedFolders.count)개 · 세션 \(selectedSessions)개").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
                Button("가져오기") { Task { await runImport() } }
                    .buttonStyle(InkButtonStyle(height: 26))
                    .disabled(selectedFolders.isEmpty)
                    .keyboardShortcut(.defaultAction)
            case .importing(let current):
                ProgressView().controlSize(.small)
                Text(stopping ? "지금 세션을 마치고 멈추는 중…" : current)
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate).lineLimit(1).truncationMode(.middle)
                Spacer()
                // 세션 하나를 마친 뒤 멈춘다 — 그때까지 가져온 것은 남는다.
                Button("멈추기") {
                    stopping = true
                    importTask?.cancel()
                }
                .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
                .disabled(stopping)
                .help("지금 가져오는 세션을 마치고 멈춥니다. 그때까지 가져온 프로젝트 · 대화는 남습니다.")
            case .done:
                Spacer()
                Button("닫기") { dismiss() }.buttonStyle(InkButtonStyle(height: 26)).keyboardShortcut(.defaultAction)
            case .scanning:
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func scan() async {
        // 시트를 닫으면(`.task` 취소) 뒤에서 도는 훑기도 멈춘다 — 큰 기록을 끝까지 읽지 않게.
        let stop = SessionImportScanner.StopFlag()
        let counter = scanCounter
        let found: [ImportFolder] = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                SessionImportScanner.scan(progress: { done, total in
                    Task { @MainActor in counter.update(done: done, total: total) }
                }, isStopped: { stop.isSet })
            }.value
        } onCancel: {
            stop.set()
        }
        guard !Task.isCancelled else { return }
        folders = found
        selected = Set(found.filter(\.recommended).map(\.id))
        phase = .ready
    }

    private func runImport() async {
        let chosen = selectedFolders
        phase = .importing("준비 중…")
        stopping = false
        let task = Task { @MainActor in
            let result = await model.importSessions(folders: chosen) { current in
                await MainActor.run { phase = .importing(current) }
            }
            phase = .done(result)
        }
        importTask = task
        await task.value
        importTask = nil
    }
}

/// 기록 가져오기의 훑기 진행 (세션 파일 수). 훑는 쪽(뒤의 스레드)이 메인 액터로 넘겨 쓴다.
@MainActor
@Observable
final class ImportScanCounter {
    private(set) var done = 0
    private(set) var total = 0

    /// 여러 스레드가 알려 순서가 바뀔 수 있다 — 줄어들지 않게.
    func update(done: Int, total: Int) {
        if total != self.total { self.done = 0 }
        self.total = total
        self.done = max(self.done, done)
    }
}
