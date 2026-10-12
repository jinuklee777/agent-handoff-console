import AppKit
import SwiftUI

/// 입력창 "/" 목록에서 쓰는 키 — 입력창 텍스트 뷰의 대리자가 먼저 묻는다 (`ReturnKeyDelegate`). 목록이 받으면 텍스트 뷰는 아무것도 하지 않는다.
enum ComposerSlashKey: Equatable {
    case up, down, accept, dismiss

    /// 텍스트 뷰 명령 → 목록 키. ↵ 는 수식키가 없을 때만 (⇧↵ · ⌥↵ 는 줄바꿈 그대로).
    init?(selector: Selector, flags: NSEvent.ModifierFlags) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): self = .up
        case #selector(NSResponder.moveDown(_:)): self = .down
        case #selector(NSResponder.insertTab(_:)): self = .accept
        case #selector(NSResponder.insertNewline(_:)):
            guard flags.isDisjoint(with: [.shift, .option, .control, .command]) else { return nil }
            self = .accept
        case #selector(NSResponder.cancelOperation(_:)): self = .dismiss
        default: return nil
        }
    }
}

/// 입력창 "/" 목록이 지금 보일 것 (`ComposerView.slashContent`).
struct SlashMenuContent {
    /// 찾을 말에 맞는 명령 · 스킬 (고를 수 있는 줄).
    var matches: [SlashCommand]
    /// 목록을 받는 중.
    var loading: Bool
    /// 고를 줄이 없을 때의 한 줄 — 받지 못한 까닭 · 쓸 수 있는 스킬이 없다.
    var note: String?
}

/// 입력창 안, 글 칸 위의 "/" 목록 (입력창 상자 안에 들어가 상자와 함께 자란다). 줄마다 이름 · 인수 안내 · 설명 한 줄.
/// ↑ ↓ 고르기 · ⇥ ↵ 넣기 · esc 닫기 (키는 입력창 텍스트 뷰가 받아 넘긴다), 누르면 넣는다.
struct SlashCommandMenu: View {
    let provider: AgentProvider
    let content: SlashMenuContent
    let selection: Int
    let onPick: (SlashCommand) -> Void

    static let rowHeight: CGFloat = 26
    /// 이보다 많으면 목록 칸만 스크롤한다 (입력창이 대화를 가리지 않게).
    static let visibleRows = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if content.matches.isEmpty {
                if let note = content.note {
                    Text(note)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                rows
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.hair).frame(height: 1).padding(.horizontal, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: String {
        provider == .codex ? "Codex 스킬" : "\(provider.displayName) 명령 · 스킬"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.ui(.caption, .semibold))
                .foregroundStyle(Theme.slate)
            if content.loading {
                SpinningLayer(content: .ring(color: Theme.slate2, lineWidth: 1.2, trim: 0.7), period: 0.9)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel("목록을 받는 중")
                if content.matches.isEmpty {
                    Text("목록을 받는 중…")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                }
            }
            Spacer(minLength: 8)
            if !content.matches.isEmpty {
                Text("↑↓ 고르기 · ↵ 넣기 · esc 닫기")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var rows: some View {
        let count = content.matches.count
        let height = CGFloat(min(count, Self.visibleRows)) * Self.rowHeight
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(content.matches.enumerated()), id: \.element.name) { index, command in
                        SlashCommandRow(provider: provider, command: command, selected: index == selection) {
                            onPick(command)
                        }
                        .frame(height: Self.rowHeight)
                        .id(index)
                    }
                }
            }
            .scrollIndicators(count > Self.visibleRows ? .automatic : .never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: height)
            .onChange(of: selection) { _, new in proxy.scrollTo(new) }
        }
    }
}

private struct SlashCommandRow: View {
    let provider: AgentProvider
    let command: SlashCommand
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let name = SlashCommands.shownName(command, provider: provider)
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name)
                    .font(Theme.mono(.callout, selected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
                if !command.argumentHint.isEmpty {
                    Text(command.argumentHint)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
                Text(command.description)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background {
                // 어두운 화면에서는 흰 카드와 입력창 바탕이 거의 같은 색이라 (#20201F · #1E1E1D) 고른 줄에 선을 두른다.
                if selected {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.card.opacity(0.55))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(command.description.isEmpty ? name : "\(name) — \(command.description)")
        .accessibilityLabel(command.description.isEmpty ? name : "\(name), \(command.description)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
