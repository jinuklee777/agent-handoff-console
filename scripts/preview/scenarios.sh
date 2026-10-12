#!/bin/bash
# 화면 확인용 git 저장소 상태를 만든다. 결과: $PREVIEW_DIR/repos/<시나리오>/<프로젝트 폴더>, 경로는 $PREVIEW_DIR/repos/<시나리오>.path
# PREVIEW_DIR 기본값은 $TMPDIR/ahc-preview — 임시 폴더라야 git 쓰기 · 합성 실행을 하는 미리보기 인수가 동작한다. 인수 없이 부르면 기본 시나리오 전부.
# 기본: main clean committed incoming diverged conflict norepo many noupstream bigdiff
# 실패 표시: pushreject(fetch 전 업로드 거절) authfail(가짜 ssh 로 공개 키 거절 — 네트워크 없음) pulloverlap(받기 겹침) incomingfiles(도착 + 내 변경)
# 브랜치 · 동기화: s3branches(로컬 · 원격에만 있는 브랜치 여럿) s3push(pre-push 훅 4초 — 진행 중) s3pushfast s3target  (main · committed 가 먼저 있어야 함)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREVIEW_DIR="${PREVIEW_DIR:-${TMPDIR:-/tmp}/ahc-preview}"
R=$PREVIEW_DIR/repos
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
G() { git -c user.name="${WHO:-hana}" -c user.email="${WHO:-hana}@example.com" -c init.defaultBranch=main \
        -c commit.gpgsign=false -c advice.detachedHead=false "$@"; }
ago() { date -v-"$1" "+%Y-%m-%dT%H:%M:%S"; }
commit() { # dir message age
  (cd "$1" && G add -A && GIT_AUTHOR_DATE="$(ago "$3")" GIT_COMMITTER_DATE="$(ago "$3")" G commit -q -m "$2")
}
sub() { perl -0pi -e "$1" "$2"; }

base_files() { # dir
  mkdir -p "$1/Moa/Auth" "$1/Moa/Login" "$1/Moa/Resources" "$1/docs"
  cat > "$1/Moa/Auth/AuthViewModel.swift" <<'EOF'
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    private let api: APIClient
    @Published private(set) var state: State = .idle

    init(api: APIClient = .shared) {
        self.api = api
    }

    func refresh() async {
        guard let token = try? await api.refreshToken() else {
            state = .signedOut
            return
        }
        state = .signedIn(token)
    }

    func signOut() {
        api.clearSession()
    }
}
EOF
  cat > "$1/Moa/Login/LoginView.swift" <<'EOF'
import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @StateObject private var viewModel = AuthViewModel()

    var body: some View {
        VStack(spacing: 16) {
            TextField("이메일", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField("비밀번호", text: $password)
                .textContentType(.password)
        }
        .padding()
        .navigationTitle("로그인")
        .task {
            await viewModel.refresh()
        }
    }
}
EOF
  printf 'struct LegacyTokenStore {\n    var token: String?\n}\n' > "$1/Moa/Auth/LegacyTokenStore.swift"
  printf '# Moa\n\n로그인 모듈.\n' > "$1/README.md"
}

# origin(bare) + 작업 폴더를 만든다. 작업 폴더는 feature/login 을 추적한다.
make_pair() { # scenario project
  local s=$1 p=$2
  rm -rf "$R/$s"; mkdir -p "$R/$s"
  G init -q --bare "$R/$s/origin.git"
  G init -q "$R/$s/$p"
  base_files "$R/$s/$p"
  (cd "$R/$s/$p" && G add -A && GIT_AUTHOR_DATE="$(ago 3d)" GIT_COMMITTER_DATE="$(ago 3d)" G commit -q -m "초기 로그인 모듈")
  (cd "$R/$s/$p" && G remote add origin "$R/$s/origin.git" && G push -q -u origin main 2>/dev/null)
  (cd "$R/$s/$p" && G switch -q -c feature/login && G push -q -u origin feature/login 2>/dev/null)
  echo "$R/$s/$p" > "$R/$s.path"
}

# 다른 사람이 origin 에 커밋을 올린다.
remote_commits() { # scenario branch n
  local s=$1 b=$2 n=$3
  rm -rf "$R/$s/other"
  G clone -q -b "$b" "$R/$s/origin.git" "$R/$s/other" 2>/dev/null
  local subjects=("토큰 만료 시 재시도 간격 조정" "로그인 버튼 비활성 조건 수정" "AuthTransport 테스트 더블 추가")
  local ages=(1H 40M 25M)
  for i in $(seq 0 $((n - 1))); do
    mkdir -p "$R/$s/other/MoaTests"
    printf '// %s\n' "${subjects[$i]}" > "$R/$s/other/MoaTests/Remote$i.swift"
    (cd "$R/$s/other" && G add -A && WHO=minji GIT_AUTHOR_DATE="$(ago ${ages[$i]})" GIT_COMMITTER_DATE="$(ago ${ages[$i]})" \
       git -c user.name=minji -c user.email=minji@example.com -c commit.gpgsign=false commit -q -m "${subjects[$i]}")
  done
  (cd "$R/$s/other" && G push -q origin "$b" 2>/dev/null)
}

local_commits() { # dir n
  local d=$1 n=$2
  local subjects=("AuthTransport 프로토콜 추가" "로그인 전송 계층 분리와 토큰 갱신 경로 정리" "토큰 저장소 이름 정리" "SSO 콜백 처리" "엔터프라이즈 로그인 버튼")
  local ages=(1H 12M 8M 5M 2M)
  for i in $(seq 0 $((n - 1))); do
    printf '// %s\n' "${subjects[$i]}" > "$d/Moa/Auth/Local$i.swift"
    (cd "$d" && G add -A && GIT_AUTHOR_DATE="$(ago ${ages[$i]})" GIT_COMMITTER_DATE="$(ago ${ages[$i]})" G commit -q -m "${subjects[$i]}")
  done
}

main_changes() { # dir  — 목업 Main: M(스테이지) · M(일부) · A(스테이지) · D(스테이지 안 됨)
  local d=$1
  sub 's/private let api: APIClient/private let transport: AuthTransport\n    private var refreshTask: Task<Token, Error>?/' "$d/Moa/Auth/AuthViewModel.swift"
  sub 's/api\.clearSession\(\)/refreshTask?.cancel()\n        transport.clearSession()/' "$d/Moa/Auth/AuthViewModel.swift"
  (cd "$d" && G add Moa/Auth/AuthViewModel.swift)
  sub 's/TextField\("이메일", text: \$email\)/EmailField(text: \$email)/' "$d/Moa/Login/LoginView.swift"
  (cd "$d" && G add Moa/Login/LoginView.swift)
  sub 's/            await viewModel\.refresh\(\)/            if viewModel.state == .idle {\n                await viewModel.refresh()\n            }/' "$d/Moa/Login/LoginView.swift"
  printf 'protocol AuthTransport {\n    func refresh() async throws -> Token\n    func clearSession()\n}\n' > "$d/Moa/Auth/AuthTransport.swift"
  (cd "$d" && G add Moa/Auth/AuthTransport.swift)
  rm "$d/Moa/Auth/LegacyTokenStore.swift"
}

build_main() { make_pair main moa-ios; local d="$R/main/moa-ios"; local_commits "$d" 2; main_changes "$d"; }
build_clean() { make_pair clean moa-ios; }
build_committed() { make_pair committed moa-ios; local d="$R/committed/moa-ios"; local_commits "$d" 3; rm "$d/Moa/Auth/LegacyTokenStore.swift"; }
build_incoming() { make_pair incoming moa-ios; remote_commits incoming feature/login 3; (cd "$R/incoming/moa-ios" && G fetch -q origin); }
build_diverged() { make_pair diverged moa-ios; local d="$R/diverged/moa-ios"; local_commits "$d" 2; remote_commits diverged feature/login 3; (cd "$d" && G fetch -q origin); }
build_noupstream() {
  make_pair noupstream moa-ios; local d="$R/noupstream/moa-ios"
  (cd "$d" && G switch -q -c feature/sso main); local_commits "$d" 2
}
build_conflict() {
  make_pair conflict moa-ios; local d="$R/conflict/moa-ios"
  sub 's/state = \.signedOut$/state = .signedOut(reason: .expired)/m' "$d/Moa/Auth/AuthViewModel.swift"
  commit "$d" "만료 사유 추가" 30M
  rm -rf "$R/conflict/other"; G clone -q -b feature/login "$R/conflict/origin.git" "$R/conflict/other" 2>/dev/null
  local o="$R/conflict/other"
  sub 's/state = \.signedOut$/state = .signedOut(reason: .network)/m' "$o/Moa/Auth/AuthViewModel.swift"
  sub 's/비밀번호/암호/' "$o/Moa/Login/LoginView.swift"
  mkdir -p "$o/MoaTests"; printf 'final class AuthTransportMock {}\n' > "$o/MoaTests/AuthTransportMock.swift"
  (cd "$o" && G add -A && git -c user.name=minji -c user.email=minji@example.com -c commit.gpgsign=false commit -q -m "네트워크 사유 추가" && G push -q origin feature/login 2>/dev/null)
  (cd "$d" && G fetch -q origin && (G merge --no-edit origin/feature/login >/dev/null 2>&1 || true))
}
build_norepo() {
  rm -rf "$R/norepo"; mkdir -p "$R/norepo/moa-design-assets"; printf 'logo\n' > "$R/norepo/moa-design-assets/logo.txt"
  echo "$R/norepo/moa-design-assets" > "$R/norepo.path"
}
build_many() {
  make_pair many moa-ios; local d="$R/many/moa-ios"
  (cd "$d" && G switch -q -c feature/login-sso-migration-for-enterprise-accounts && G push -q -u origin feature/login-sso-migration-for-enterprise-accounts 2>/dev/null)
  local_commits "$d" 5
  main_changes "$d"
  mkdir -p "$d/Moa/Auth/Enterprise" "$d/MoaTests/Enterprise" "$d/Moa/Login/Components" "$d/Moa/Settings"
  printf 'final class EnterpriseSSOCoordinatorWithVeryLongNameForTokenMigrationFlow {}\n' > "$d/Moa/Auth/Enterprise/EnterpriseSSOCoordinatorWithVeryLongNameForTokenMigrationFlow.swift"
  for i in $(seq 1 40); do printf 'let value%d = %d\n' "$i" "$i" > "$d/Moa/Settings/Generated$i.swift"; done
  (cd "$d" && G add Moa/Settings/Generated1*.swift)
  echo "$R/many/moa-ios" > "$R/many.path"
}
build_bigdiff() { # 5,000줄 넘는 diff
  make_pair bigdiff moa-ios; local d="$R/bigdiff/moa-ios"
  for i in $(seq 1 6000); do echo "let line$i = \"original $i\""; done > "$d/Moa/Big.swift"
  (cd "$d" && G add -A && G commit -q -m "큰 파일")
  for i in $(seq 1 6000); do if [ $((i % 2)) -eq 0 ]; then echo "let line$i = \"changed value $i with a much longer tail so that wrapping happens in the narrow panel view\""; else echo "let line$i = \"original $i\""; fi; done > "$d/Moa/Big.swift"
}

# ── 실패 표시용 (작은 파일 세트) ──
small_files() {
  mkdir -p "$1/Moa/Auth" "$1/Moa/Login"
  printf 'import Foundation\n\nfinal class AuthViewModel {}\n' > "$1/Moa/Auth/AuthViewModel.swift"
  printf 'import SwiftUI\n\nstruct LoginView: View {\n    var body: some View { Text("로그인") }\n}\n' > "$1/Moa/Login/LoginView.swift"
  printf '# Moa\n' > "$1/README.md"
}

make_small_pair() { # scenario project
  local s=$1 p=$2
  rm -rf "$R/$s"; mkdir -p "$R/$s"
  G init -q --bare "$R/$s/origin.git"
  G init -q "$R/$s/$p"
  small_files "$R/$s/$p"
  (cd "$R/$s/$p" && G add -A && GIT_AUTHOR_DATE="$(ago 3d)" GIT_COMMITTER_DATE="$(ago 3d)" G commit -q -m "초기 로그인 모듈")
  (cd "$R/$s/$p" && G remote add origin "$R/$s/origin.git" && G push -q -u origin main 2>/dev/null)
  (cd "$R/$s/$p" && G switch -q -c feature/login && G push -q -u origin feature/login 2>/dev/null)
  echo "$R/$s/$p" > "$R/$s.path"
}

small_commits() { # dir n
  local d=$1 n=$2
  local subjects=("AuthTransport 프로토콜 추가" "로그인 전송 계층 분리와 토큰 갱신 경로 정리")
  local ages=(1H 12M)
  for i in $(seq 0 $((n - 1))); do
    printf '// %s\n' "${subjects[$i]}" > "$d/Moa/Auth/Local$i.swift"
    (cd "$d" && G add -A && GIT_AUTHOR_DATE="$(ago ${ages[$i]})" GIT_COMMITTER_DATE="$(ago ${ages[$i]})" G commit -q -m "${subjects[$i]}")
  done
}

other_clone() { # scenario
  rm -rf "$R/$1/other"
  G clone -q -b feature/login "$R/$1/origin.git" "$R/$1/other" 2>/dev/null
}

build_pushreject() {
  make_small_pair pushreject moa-ios; local d="$R/pushreject/moa-ios"
  small_commits "$d" 2
  other_clone pushreject; local o="$R/pushreject/other"
  local subjects=("토큰 만료 시 재시도 간격 조정" "로그인 버튼 비활성 조건 수정" "AuthTransport 테스트 더블 추가")
  local ages=(1H 40M 25M)
  for i in 0 1 2; do
    mkdir -p "$o/MoaTests"; printf '// %s\n' "${subjects[$i]}" > "$o/MoaTests/Remote$i.swift"
    (cd "$o" && G add -A && GIT_AUTHOR_DATE="$(ago ${ages[$i]})" GIT_COMMITTER_DATE="$(ago ${ages[$i]})" \
       git -c user.name=minji -c user.email=minji@example.com -c commit.gpgsign=false commit -q -m "${subjects[$i]}")
  done
  (cd "$o" && G push -q origin feature/login 2>/dev/null)
  # 이쪽은 fetch 하지 않는다 → 마지막 확인 기준으로는 업로드 대기(ahead 2)
}

build_authfail() {
  make_small_pair authfail moa-ios; local d="$R/authfail/moa-ios"
  small_commits "$d" 2
  cat > "$R/authfail/fake-ssh.sh" <<'EOF'
#!/bin/sh
# 네트워크 없이 서버의 공개 키 거절 문장을 쓴다 (git 은 실제로 이 전송을 부른다).
echo "git@github.com: Permission denied (publickey)." >&2
exit 255
EOF
  chmod +x "$R/authfail/fake-ssh.sh"
  (cd "$d" && G remote set-url origin git@github.com:moa/moa-ios.git && git config core.sshCommand "$R/authfail/fake-ssh.sh")
}

build_pulloverlap() {
  make_small_pair pulloverlap moa-ios; local d="$R/pulloverlap/moa-ios"
  other_clone pulloverlap; local o="$R/pulloverlap/other"
  perl -0pi -e 's/Text\("로그인"\)/Text("로그인하기")/' "$o/Moa/Login/LoginView.swift"
  (cd "$o" && GIT_AUTHOR_DATE="$(ago 25M)" GIT_COMMITTER_DATE="$(ago 25M)" \
     git -c user.name=minji -c user.email=minji@example.com -c commit.gpgsign=false commit -q -am "로그인 버튼 문구 수정" \
     && G push -q origin feature/login 2>/dev/null)
  (cd "$d" && G fetch -q origin)
  perl -0pi -e 's/Text\("로그인"\)/Text("로그인 (내 수정)")/' "$d/Moa/Login/LoginView.swift"
}

build_incomingfiles() { # 원격 변경 도착(behind 3) + 내 변경(겹치지 않음, 일부 스테이지) → 커밋이 잉크, 받기는 흰 칩
  make_small_pair incomingfiles moa-ios; local d="$R/incomingfiles/moa-ios"
  other_clone incomingfiles; local o="$R/incomingfiles/other"
  local subjects=("토큰 만료 시 재시도 간격 조정" "로그인 버튼 비활성 조건 수정" "AuthTransport 테스트 더블 추가")
  local ages=(1H 40M 25M)
  for i in 0 1 2; do
    mkdir -p "$o/MoaTests"; printf '// %s\n' "${subjects[$i]}" > "$o/MoaTests/Remote$i.swift"
    (cd "$o" && G add -A && GIT_AUTHOR_DATE="$(ago ${ages[$i]})" GIT_COMMITTER_DATE="$(ago ${ages[$i]})" \
       git -c user.name=minji -c user.email=minji@example.com -c commit.gpgsign=false commit -q -m "${subjects[$i]}")
  done
  (cd "$o" && G push -q origin feature/login 2>/dev/null)
  (cd "$d" && G fetch -q origin)
  perl -0pi -e 's/Text\("로그인"\)/Text("로그인 (내 수정)")/' "$d/Moa/Login/LoginView.swift"
  printf 'protocol AuthTransport {}\n' > "$d/Moa/Auth/AuthTransport.swift"
  (cd "$d" && G add Moa/Login/LoginView.swift)
}

# ── 브랜치 메뉴 · 동기화 변형용 (기본 시나리오 복사) ──
copy_scenario() { # 원본 새이름
  local from=$1 to=$2
  rm -rf "${R:?}/$to"; cp -R "$R/$from" "$R/$to"
  local proj; proj=$(basename "$(cat "$R/$from.path")")
  (cd "$R/$to/$proj" && G remote set-url origin "$R/$to/origin.git")
  echo "$R/$to/$proj" > "$R/$to.path"
}

commit_on() { # dir branch base file message age [who]
  local d=$1 b=$2 base=$3 f=$4 m=$5 a=$6 who=${7:-hana}
  (cd "$d" && G switch -q -c "$b" "$base" 2>/dev/null || G switch -q "$b")
  mkdir -p "$d/$(dirname "$f")"; printf '// %s\n' "$m" > "$d/$f"
  (cd "$d" && G add -- "$f" && GIT_AUTHOR_DATE="$(ago "$a")" GIT_COMMITTER_DATE="$(ago "$a")" \
     git -c user.name="$who" -c user.email="$who@example.com" -c commit.gpgsign=false commit -q -m "$m")
}

build_s3branches() {
  copy_scenario main s3branches
  local s=$R/s3branches
  # 다른 사람 클론에서 원격에만 있는 브랜치를 올린다
  rm -rf "$s/other"; G clone -q "$s/origin.git" "$s/other" 2>/dev/null
  commit_on "$s/other" release/2.4 origin/main Moa/Release.swift "2.4 릴리스 준비" 5d minji
  commit_on "$s/other" feature/login-a11y origin/main Moa/Login/A11y.swift "로그인 접근성 레이블" 1d sora
  commit_on "$s/other" feature/sso-callback origin/main Moa/Auth/SSOCallback.swift "SSO 콜백" 20H minji
  (cd "$s/other" && G push -q origin release/2.4 feature/login-a11y feature/sso-callback 2>/dev/null)
  # 이쪽 로컬 브랜치 (작업 폴더의 변경은 그대로 둔 채 워크트리로 커밋한다)
  local d; d=$(cat "$R/s3branches.path")
  rm -rf "$s/wt"; (cd "$d" && G worktree add -q "$s/wt" main 2>/dev/null)
  commit_on "$s/wt" fix/payment-retry main Moa/Pay/Retry.swift "결제 재시도 간격" 3d
  (cd "$s/wt" && G push -q -u origin fix/payment-retry 2>/dev/null)
  commit_on "$s/wt" fix/payment-retry fix/payment-retry Moa/Pay/Retry2.swift "결제 재시도 로그" 3d
  commit_on "$s/wt" feature/onboarding-flow-redesign-with-token-migration main Moa/Onboarding.swift "온보딩 흐름" 14d
  commit_on "$s/wt" feature/login-sso main Moa/Auth/SSO.swift "SSO 로그인 초안" 4d
  (cd "$s/wt" && G switch -q --detach main)
  (cd "$d" && G worktree remove --force "$s/wt" && G fetch -q origin)
}

build_s3push() {
  copy_scenario committed s3push
  local d; d=$(cat "$R/s3push.path")
  mkdir -p "$d/.git/hooks"
  printf '#!/bin/sh\nsleep 4\nexit 0\n' > "$d/.git/hooks/pre-push"; chmod +x "$d/.git/hooks/pre-push"
  (cd "$d" && git config core.hooksPath "$d/.git/hooks")
}

build_s3pushfast() { copy_scenario committed s3pushfast; }
build_s3target() { copy_scenario committed s3target; }

mkdir -p "$R"
for s in "${@:-main clean committed incoming diverged conflict norepo many noupstream bigdiff}"; do
  for one in $s; do "build_$one"; echo "ok $one → $(cat "$R/$one.path")"; done
done
