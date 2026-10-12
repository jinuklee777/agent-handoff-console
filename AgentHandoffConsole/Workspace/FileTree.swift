import Foundation
import Darwin

/// 인스펙터 파일 트리. 폴더를 펼칠 때 그 폴더만 읽는다.
struct FileNode: Identifiable, Hashable, Sendable {
    /// 프로젝트 폴더 기준 경로.
    var id: String { path }
    var path: String
    var name: String
    var isDirectory: Bool
}

enum FileTree {
    /// 트리와 이름 검색에서 건너뛰는 폴더. 빌드 산출물과 의존성은 보여줘도 도움이 되지 않는다.
    static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".venv", "venv", "__pycache__",
        ".next", ".gradle", "Pods", ".terraform", ".swiftpm", ".idea",
    ]
    static let skippedFiles: Set<String> = [".DS_Store"]

    /// `relativeDirectory` 바로 아래 항목. 폴더 먼저, 이름순.
    static func children(of relativeDirectory: String, root: URL) -> [FileNode] {
        let url = relativeDirectory.isEmpty ? root : root.appendingPathComponent(relativeDirectory)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: []) else {
            return []
        }
        var nodes: [FileNode] = []
        for item in items {
            let name = item.lastPathComponent
            if skippedFiles.contains(name) { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDirectory = values?.isDirectory == true
            if isDirectory && skippedDirectories.contains(name) { continue }
            let path = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
            nodes.append(FileNode(path: path, name: name, isDirectory: isDirectory))
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Git 이 아닐 때 이름 검색용 파일 목록.
    static func enumerateFiles(at root: URL, limit: Int) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return [] }
        var files: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if skippedDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if skippedFiles.contains(name) { continue }
            let path = url.standardizedFileURL.path
            files.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : name)
            if files.count >= limit { break }
        }
        return files
    }
}

/// 파일 탭이 폴더마다 기억하는 화면 상태 — 탭을 옮겼다 돌아와도 펼친 폴더 · 찾는 글자가 남는다 (chg-4, `AppModel.filesTreeMemory`).
struct FilesTreeMemory: Equatable, Sendable {
    var expanded: Set<String> = []
    var query = ""
    /// 찾기 방식 (`FilesPane.SearchMode` 의 값 — "이름" · "내용").
    var mode = ""
    var changedOnly = false
    var selectedPath: String?
}

/// 파일 탭에서 파일을 열 때의 안전 규칙 (chg-5). 대화 링크(`LinkOpener`)처럼 **실행될 수 있는 파일은 열지 않고 Finder 에서 보인다** —
/// 에이전트가 만들었거나 받아 온 저장소의 `setup.command` · `.app` · 실행 비트가 선 스크립트를 두 번 눌러 바로 돌리지 않게.
/// 그 밖의 문서는 기본 앱으로 연다 (미리 보기가 없으니 내용을 보려면 그것이 맞다).
///
/// 심볼릭 링크 · Finder 별칭은 **끝까지 따라간 대상**으로 판정한다 (`facts(of:defaultApp:)`) — `NSWorkspace.open` 은 링크를 따라가
/// 대상을 연다. 링크의 이름만 보던 때는 `readme.txt -> tools/Helper.app` 이 글 파일로 보여 두 번 누르면 앱이 떴다 (2026-10-12).
enum FileOpenRule {
    enum Action: Equatable, Sendable {
        case open
        /// 실행하지 않고 Finder 에서 고른 채로 보인다. `reason` 은 도움말 · 확인 창의 까닭.
        case reveal(reason: String)
    }

    /// 판정의 재료 — 연 파일과, 링크 · 별칭이면 따라간 대상의 사실 (`facts(of:defaultApp:)` 가 읽는다).
    struct Facts: Equatable, Sendable {
        /// 연 이름 (링크면 링크 자신의 이름).
        var name: String
        /// 따라간 대상의 이름. 링크가 아니면 `name` 과 같다.
        var targetName: String
        /// 심볼릭 링크나 Finder 별칭을 따라왔다.
        var viaLink = false
        /// 끝까지 따라가지 못했다 (고리 · 깨진 링크 · 풀 수 없는 별칭 · 너무 깊은 별칭).
        var unresolved = false
        /// 대상이 폴더다 (패키지 · 앱 번들 포함).
        var isDirectory = false
        var isPackage = false
        var isApplication = false
        /// 대상의 실행 비트. 폴더는 늘 false (폴더의 x 는 들어갈 권한이다).
        var executable = false
        /// 대상을 여는 기본 앱 번들 이름 (`Terminal.app`, 모르면 nil).
        var defaultApp: String?
    }

    /// 열면 프로그램이 돌거나 설치 · 마운트 · 다른 곳을 여는 형식.
    static let launchingExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "pkg", "mpkg", "dmg", "jar", "workflow", "action", "prefpane", "saver",
        "kext", "webloc", "inetloc", "fileloc", "url", "shortcut", "osax", "xpc", "bundle",
        "plugin", "qlgenerator", "mdimporter", "service", "appex", "jnlp", "msi", "exe", "bat", "cmd", "vbs", "ps1",
    ]

    /// 실행 비트가 서 있으면 Finder 가 터미널에서 돌리는 스크립트 형식 (확장자가 없으면 실행 파일로 본다).
    static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "rb", "pl", "php", "js", "mjs", "lua", "swift", "tcl",
    ]

    /// 기본 앱이 이것이면 파일을 "실행" 한다 (터미널 · 실행기 · 설치기).
    static let launcherApps: Set<String> = [
        "Terminal.app", "iTerm.app", "iTerm2.app", "Warp.app", "Python Launcher.app", "Jar Launcher.app", "Installer.app",
        "Automator Installer.app", "Shortcuts.app",
    ]

    /// 별칭 → 별칭 … 을 따라가는 횟수의 상한. 심볼릭 링크의 고리는 `realpath` 가 끊는다 (ELOOP).
    static let aliasHopLimit = 8

    /// 그 파일을 열 때의 동작. `defaultApp` 은 따라간 대상을 여는 기본 앱의 번들 이름 — AppKit 이라 부르는 쪽이 준다
    /// (`NSWorkspace.urlForApplication(toOpen:)`).
    static func action(for url: URL, defaultApp: (URL) -> String?) -> Action {
        action(facts(of: url, defaultApp: defaultApp))
    }

    /// 파일의 사실을 읽는다. 심볼릭 링크는 `realpath` 로 경로 전체(이어진 링크 · 중간 폴더의 링크 포함)를 풀고, 그래도 별칭이면
    /// Finder 별칭이라 화면 · 마운트 없이 푼다 — 별칭의 대상이 또 링크일 수 있어 되풀이한다. 풀지 못하면 `unresolved`.
    static func facts(of url: URL, defaultApp: (URL) -> String?) -> Facts {
        let name = url.lastPathComponent
        var facts = Facts(name: name, targetName: name)
        // 심볼릭 링크도 별칭으로 센다 (`isAliasFile` — Finder 별칭 또는 심볼릭 링크).
        facts.viaLink = (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
        var target = url
        var hops = 0
        while true {
            guard let real = realPath(target.path) else {
                facts.unresolved = true
                return facts
            }
            target = URL(fileURLWithPath: real)
            guard (try? target.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true else { break }
            hops += 1
            guard hops <= aliasHopLimit,
                  let next = try? URL(resolvingAliasFileAt: target, options: [.withoutUI, .withoutMounting]) else {
                facts.unresolved = true
                return facts
            }
            target = next
        }
        facts.targetName = target.lastPathComponent
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isApplicationKey])
        facts.isDirectory = values?.isDirectory == true
        facts.isPackage = values?.isPackage == true
        facts.isApplication = values?.isApplication == true
        if !facts.isDirectory {
            facts.executable = FileManager.default.isExecutableFile(atPath: target.path)
            facts.defaultApp = defaultApp(target)
        }
        return facts
    }

    static func action(_ facts: Facts) -> Action {
        guard let reason = revealReason(facts) else { return .open }
        // Finder 에서 고르는 것은 링크 자신이라 까닭에 대상을 밝힌다.
        let followed = facts.viaLink && !facts.unresolved
        return .reveal(reason: followed ? reason + " (링크가 가리키는 대상: \(facts.targetName))" : reason)
    }

    /// 열지 않고 Finder 에서 보일 까닭. 열어도 되면 nil.
    private static func revealReason(_ facts: Facts) -> String? {
        if facts.unresolved {
            return "링크를 끝까지 따라가지 못해(고리 · 깨진 링크 · 풀 수 없는 별칭) 무엇이 열릴지 몰라 Finder 에서 보입니다."
        }
        // 링크면 링크의 이름과 대상의 이름을 둘 다 본다 — 어느 쪽이든 실행하는 형식이면 열지 않는다.
        let extensions = [facts.name, facts.targetName].map { ($0 as NSString).pathExtension.lowercased() }
        if let ext = extensions.first(where: { launchingExtensions.contains($0) }) {
            return "열면 프로그램이 실행되거나 설치 · 연결이 시작될 수 있는 형식(.\(ext))이라 Finder 에서 보입니다."
        }
        if facts.isApplication { return "열면 앱이 실행되므로 Finder 에서 보입니다." }
        if facts.isPackage { return "패키지(앱 · 번들처럼 묶인 폴더)라 열면 그 안의 프로그램이 실행될 수 있어 Finder 에서 보입니다." }
        if facts.isDirectory { return "폴더라 Finder 에서 보입니다." }
        // 링크가 가리키는 실행 파일은 확장자와 상관없이 — 이름으로 정체를 감출 수 있다.
        let ext = extensions[1]
        if facts.executable, facts.viaLink || ext.isEmpty || scriptExtensions.contains(ext) {
            return "실행할 수 있는 파일이라 Finder 에서 보입니다 (두 번 누르면 바로 실행될 수 있습니다)."
        }
        if let app = facts.defaultApp, launcherApps.contains(app) {
            return "기본 앱(\((app as NSString).deletingPathExtension))이 이 파일을 실행하므로 Finder 에서 보입니다."
        }
        return nil
    }

    /// 심볼릭 링크를 다 푼 경로. 없거나 · 깨졌거나 · 고리면 nil.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
