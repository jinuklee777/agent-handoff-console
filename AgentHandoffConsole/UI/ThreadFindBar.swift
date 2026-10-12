import SwiftUI

// 대화 안 찾기 (편집 > 대화에서 찾기 ⌘F · 다음 ⌘G · 이전 ⇧⌘G) — 막대와 그 동작. 무엇이 맞는지는 순수 판정 `ThreadFind`
// (UI/Stream/ThreadFind.swift). 대화 칸(`ThreadView`)은 상태 하나 · 수식어 하나 · 맞은 행의 강조만 갖는다.

/// 한 칸의 찾기 상태 (칸의 `@State`). 대화가 바뀌면 칸이 새로 만들어져 닫힌다.
struct ThreadFindState: Equatable {
    var visible = false
    var query = ""
    /// 지금 보이는 결과의 행 (강조 · 다음 · 이전의 기준).
    var currentRowID: String?
    /// 바뀔 때마다 찾기 칸에 포커스를 준다.
    var focusSerial = 0
}

/// 대화 스트림의 스크롤 칸에 붙는다: 위 오른쪽에 찾기 막대를 띄우고, 메뉴 명령(`AppModel.findCommand`)을 받아 결과로 옮겨 간다.
/// 결과가 아직 그리지 않은 오래된 행이면 그 행까지 그리게 `rowLimit` 를 늘리고, 옮겨 간 동안은 새 출력이 와도 끌어내리지 않는다.
struct ThreadFindModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let threadID: String
    @Binding var state: ThreadFindState
    /// 이 대화의 모든 행 (그리지 않은 오래된 행 포함).
    let rows: [StreamRow]
    @Binding var rowLimit: Int
    @Binding var followBottom: Bool
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        let matches = state.visible ? ThreadFind.matches(state.query, in: rows) : []
        content
            .overlay(alignment: .topTrailing) {
                if state.visible {
                    ThreadFindBar(state: $state, matches: matches,
                                  step: { forward in step(forward: forward) },
                                  close: close)
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                }
            }
            .onChange(of: model.findCommand) { _, command in receive(command) }
            // 에이전트 기록 화면에서 ⌘F 를 누르면 이 칸이 그 뒤에 나타난다 — 막 온 요청이면 받는다.
            .onAppear { receive(model.findCommand) }
            // 찾을 말이 바뀌면 맨 아래(가장 최근)의 결과로.
            .onChange(of: state.query) { _, _ in
                let found = ThreadFind.matches(state.query, in: rows)
                show(ThreadFind.initialIndex(count: found.count), in: found)
            }
    }

    private func receive(_ command: ThreadFind.Command?) {
        guard let command, command.threadID == threadID, command.isFresh() else { return }
        model.consumeFindCommand(serial: command.serial)
        handle(command.action)
    }

    private func handle(_ action: ThreadFind.Command.Action) {
        let wasVisible = state.visible
        state.visible = true
        switch action {
        case .open:
            state.focusSerial += 1
            // 다시 열었고 찾을 말이 남아 있으면 그 결과를 다시 보인다.
            if !wasVisible, !ThreadFind.normalized(state.query).isEmpty {
                let found = ThreadFind.matches(state.query, in: rows)
                show(ThreadFind.index(of: state.currentRowID, in: found) ?? ThreadFind.initialIndex(count: found.count),
                     in: found)
            }
        case .next, .previous:
            guard !ThreadFind.normalized(state.query).isEmpty else {
                state.focusSerial += 1
                return
            }
            step(forward: action == .next)
        }
    }

    private func step(forward: Bool) {
        let found = ThreadFind.matches(state.query, in: rows)
        show(ThreadFind.step(from: ThreadFind.index(of: state.currentRowID, in: found), count: found.count, forward: forward),
             in: found)
    }

    private func show(_ index: Int?, in found: [ThreadFind.Match]) {
        guard let index, found.indices.contains(index) else {
            state.currentRowID = nil
            return
        }
        let rowID = found[index].rowID
        state.currentRowID = rowID
        // 그리지 않은 오래된 행이면 그 행까지 그린다.
        if let position = rows.firstIndex(where: { $0.id == rowID }), rows.count - position > rowLimit {
            rowLimit = rows.count - position
        }
        // 결과를 보는 동안 새 출력이 와도 끌어내리지 않는다 (맨 아래로 스크롤하면 다시 따라간다).
        followBottom = false
        // 늘린 행이 배치된 뒤에 옮긴다 (같은 차례의 `scrollTo` 는 배치 전 위치로 간다 — 실측, `ThreadView.showOlderRows`).
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(rowID, anchor: .center) }
        }
    }

    private func close() {
        state.visible = false
        state.currentRowID = nil
    }
}

/// 찾기 막대: 찾을 말 · "3/7" · 이전 · 다음 · 닫기. ↵ 다음 · ⇧↵ 이전 · esc 닫기 (칸에 포커스가 있을 때).
struct ThreadFindBar: View {
    @Binding var state: ThreadFindState
    let matches: [ThreadFind.Match]
    let step: (Bool) -> Void
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let current = ThreadFind.index(of: state.currentRowID, in: matches)
        let counter = ThreadFind.counterText(query: state.query, current: current, matches: matches)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate2)
            TextField("대화에서 찾기", text: $state.query)
                .textFieldStyle(.plain)
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .frame(minWidth: 140)
                .onKeyPress(keys: [.return]) { press in
                    step(!press.modifiers.contains(.shift))
                    return .handled
                }
                // 키를 받지 못한 경우의 길 (필드 편집기가 먼저 받으면 ↵ 는 제출로 온다).
                .onSubmit { step(!NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand(perform: close)
                .accessibilityLabel("대화에서 찾을 말")
            if !counter.isEmpty {
                Text(counter)
                    .font(Theme.digits(.caption))
                    .foregroundStyle(matches.isEmpty ? Theme.danger : Theme.slate)
                    .fixedSize()
                    .help(ThreadFind.counterHelp(matches: matches))
                    .accessibilityLabel(matches.isEmpty ? "결과 없음" : "결과 \(counter)")
            }
            IconButton(systemName: "chevron.up", size: 10, color: Theme.control,
                       help: "이전 결과 (\(MenuShortcut.findPrevious.symbol))") { step(false) }
                .disabled(matches.isEmpty)
            IconButton(systemName: "chevron.down", size: 10, color: Theme.control,
                       help: "다음 결과 (\(MenuShortcut.findNext.symbol))") { step(true) }
                .disabled(matches.isEmpty)
            IconButton(systemName: "xmark", size: 9, color: Theme.control, help: "찾기 닫기 (esc)", action: close)
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 30)
        .frame(maxWidth: 380)
        .cardSurface(radius: 8)
        .onAppear { fieldFocused = true }
        .onChange(of: state.focusSerial) { _, _ in fieldFocused = true }
    }
}

/// 찾기 결과로 보고 있는 행의 강조 — 옅은 노란 바탕 (`Theme.matchHighlight`, 파일 찾기 · diff 와 같은 색).
struct FindHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.background {
            if active {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.matchHighlight)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
                    .accessibilityHidden(true)
            }
        }
    }
}
