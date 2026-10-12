#!/bin/bash
# README 소개 이미지용 시나리오 저장소 (make.sh 가 부른다). 결과: $PREVIEW_DIR/repos/<이름>/{moa-ios, moa-server, moa-web, stages/A, stages/B}
#   moa-ios  : feature/login-retry, 업로드할 커밋 2개, 작업 트리는 깨끗 — 단계 A · B 는 seed 가 적용하며 실행 전후를 찍는다
#   stages/A : Claude 가 한 일 (AuthTransport 401 재시도 · AuthError.sessionExpired · AuthRetryTests)
#   stages/B : Codex 가 이어서 한 일 (LoginView 오류 문구 · LoginViewModel.message(for:) · LoginErrorMessageTests)
#   moa-server · moa-web : 사이드바에만 보이는 다른 프로젝트
# 임시 폴더($TMPDIR/ahc-preview) 안이라야 미리보기 인수가 동작한다.
set -euo pipefail
PREVIEW_DIR="${PREVIEW_DIR:-${TMPDIR:-/tmp}/ahc-preview}"
R=$PREVIEW_DIR/repos/${1:-readme}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
G() { git -c user.name=hana -c user.email=hana@example.com -c init.defaultBranch=main \
        -c commit.gpgsign=false -c advice.detachedHead=false "$@"; }
ago() { date -v-"$1" "+%Y-%m-%dT%H:%M:%S"; }
commit() { # dir message age
  (cd "$1" && G add -A && GIT_AUTHOR_DATE="$(ago "$3")" GIT_COMMITTER_DATE="$(ago "$3")" G commit -q -m "$2")
}

rm -rf "$R"; mkdir -p "$R"

# ───────────────────────── moa-ios ─────────────────────────
D=$R/moa-ios
G init -q --bare "$R/moa-ios-origin.git"
G init -q "$D"
mkdir -p "$D/Moa/Auth" "$D/Moa/Login" "$D/MoaTests"

cat > "$D/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moa",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(name: "Moa", path: "Moa"),
        .testTarget(name: "MoaTests", dependencies: ["Moa"], path: "MoaTests"),
    ]
)
EOF
printf '# Moa\n\n모아 iOS 앱. 로그인 · 인증 모듈.\n' > "$D/README.md"

cat > "$D/Moa/Auth/AuthError.swift" <<'EOF'
import Foundation

enum AuthError: Error, Equatable {
    case invalidResponse
}
EOF

cat > "$D/Moa/Auth/TokenStore.swift" <<'EOF'
import Foundation

struct Token: Equatable, Sendable {
    var value: String
    var expiresAt: Date
}

/// 토큰을 읽고 갱신한다.
actor TokenStore {
    private var token: Token?
    private let refresher: @Sendable () async throws -> Token

    init(refresher: @escaping @Sendable () async throws -> Token) {
        self.refresher = refresher
    }

    func current() async throws -> Token {
        if let token, token.expiresAt > .now { return token }
        return try await refresh()
    }

    @discardableResult
    func refresh() async throws -> Token {
        let fresh = try await refresher()
        token = fresh
        return fresh
    }
}
EOF

cat > "$D/Moa/Auth/AuthTransport.swift" <<'EOF'
import Foundation

/// 인증이 필요한 요청을 보내는 전송 계층.
final class AuthTransport: Sendable {
    private let session: URLSession
    private let tokens: TokenStore

    init(session: URLSession = .shared, tokens: TokenStore) {
        self.session = session
        self.tokens = tokens
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: authorized(request))
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        return data
    }

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        let token = try await tokens.current()
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        return request
    }
}
EOF

cat > "$D/Moa/Auth/AuthService.swift" <<'EOF'
import Foundation

/// 로그인 · 로그아웃. 화면은 이 타입만 안다.
final class AuthService: Sendable {
    static let shared = AuthService()

    func signIn(email: String, password: String) async throws {
        // 서버 로그인 요청 (생략)
    }

    func signOut() async {
        // 세션 정리 (생략)
    }
}
EOF

cat > "$D/Moa/Login/LoginViewModel.swift" <<'EOF'
import Foundation
import Observation

@MainActor
@Observable
final class LoginViewModel {
    var email = ""
    var password = ""
    private(set) var errorMessage: String?
    private let auth: AuthService

    init(auth: AuthService = .shared) {
        self.auth = auth
    }

    var canSubmit: Bool { !email.isEmpty && !password.isEmpty }

    func signIn() async {
        do {
            try await auth.signIn(email: email, password: password)
            errorMessage = nil
        } catch {
            errorMessage = "로그인에 실패했습니다."
        }
    }
}
EOF

cat > "$D/Moa/Login/LoginView.swift" <<'EOF'
import SwiftUI

struct LoginView: View {
    @State private var viewModel = LoginViewModel()

    var body: some View {
        VStack(spacing: 16) {
            TextField("이메일", text: $viewModel.email)
                .textContentType(.username)
            SecureField("비밀번호", text: $viewModel.password)
                .textContentType(.password)
            Button("로그인") {
                Task { await viewModel.signIn() }
            }
            .disabled(!viewModel.canSubmit)
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .navigationTitle("로그인")
    }
}
EOF

cat > "$D/MoaTests/AuthTransportTests.swift" <<'EOF'
import XCTest
@testable import Moa

final class AuthTransportTests: XCTestCase {
    func testAddsBearerHeader() async throws {
        let (transport, stub) = makeTransport(responses: [200])
        _ = try await transport.send(URLRequest(url: .api("/me")))
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer t1")
    }
}
EOF

(cd "$D" && G add -A && GIT_AUTHOR_DATE="$(ago 3d)" GIT_COMMITTER_DATE="$(ago 3d)" G commit -q -m "로그인 모듈 초기 구성")
(cd "$D" && G remote add origin "$R/moa-ios-origin.git" && G push -q -u origin main 2>/dev/null)
(cd "$D" && G switch -q -c feature/login-retry && G push -q -u origin feature/login-retry 2>/dev/null)

# 업로드하지 않은 커밋 2개 — 토큰 갱신 합치기 · 401 구분
cat > "$D/Moa/Auth/TokenStore.swift" <<'EOF'
import Foundation

struct Token: Equatable, Sendable {
    var value: String
    var expiresAt: Date
}

/// 토큰을 읽고 갱신한다. 동시에 들어온 갱신 요청은 하나로 합친다.
actor TokenStore {
    private var token: Token?
    private var refreshing: Task<Token, Error>?
    private let refresher: @Sendable () async throws -> Token

    init(refresher: @escaping @Sendable () async throws -> Token) {
        self.refresher = refresher
    }

    func current() async throws -> Token {
        if let token, token.expiresAt > .now { return token }
        return try await refresh()
    }

    @discardableResult
    func refresh() async throws -> Token {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await refresher() }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        token = fresh
        return fresh
    }
}
EOF
commit "$D" "토큰 갱신 요청을 하나로 합침" 2H

cat > "$D/Moa/Auth/AuthError.swift" <<'EOF'
import Foundation

enum AuthError: Error, Equatable {
    case invalidResponse
    case unauthorized
}
EOF
perl -0pi -e 's/            throw AuthError.invalidResponse\n        \}\n        return data/            throw AuthError.invalidResponse\n        }\n        guard http.statusCode != 401 else {\n            throw AuthError.unauthorized\n        }\n        return data/' "$D/Moa/Auth/AuthTransport.swift"
commit "$D" "401 응답을 AuthError.unauthorized 로 구분" 70M

# ───────────────────────── 단계 A: Claude ─────────────────────────
A=$R/stages/A
mkdir -p "$A/Moa/Auth" "$A/MoaTests"
cp "$D/Moa/Auth/AuthTransport.swift" "$A/Moa/Auth/AuthTransport.swift"
perl -0pi -e 's/        guard http.statusCode != 401 else \{\n            throw AuthError.unauthorized\n        \}\n        return data\n    \}\n/        if http.statusCode == 401 {\n            try await tokens.refresh()\n            return try await retryOnce(request)\n        }\n        return data\n    }\n\n    \/\/\/ 갱신한 토큰으로 한 번만 다시 보낸다. 또 401 이면 세션이 만료된 것으로 본다.\n    private func retryOnce(_ request: URLRequest) async throws -> Data {\n        let (data, response) = try await session.data(for: authorized(request))\n        guard (response as? HTTPURLResponse)?.statusCode != 401 else {\n            throw AuthError.sessionExpired\n        }\n        return data\n    }\n/' "$A/Moa/Auth/AuthTransport.swift"
cat > "$A/Moa/Auth/AuthError.swift" <<'EOF'
import Foundation

enum AuthError: Error, Equatable {
    case invalidResponse
    case unauthorized
    /// 토큰을 갱신하고 다시 보냈는데도 401 — 다시 로그인해야 한다.
    case sessionExpired
}
EOF
cat > "$A/MoaTests/AuthRetryTests.swift" <<'EOF'
import XCTest
@testable import Moa

final class AuthRetryTests: XCTestCase {
    func testRefreshesOnceAndRetriesOn401() async throws {
        let (transport, stub) = makeTransport(responses: [401, 200])
        _ = try await transport.send(URLRequest(url: .api("/me")))
        XCTAssertEqual(stub.refreshCount, 1)
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testSecond401ThrowsSessionExpired() async throws {
        let (transport, _) = makeTransport(responses: [401, 401])
        await XCTAssertThrowsError(try await transport.send(URLRequest(url: .api("/me")))) {
            XCTAssertEqual($0 as? AuthError, .sessionExpired)
        }
    }

    func testConcurrent401sShareOneRefresh() async throws {
        let (transport, stub) = makeTransport(responses: [401, 401, 200, 200])
        async let a = transport.send(URLRequest(url: .api("/me")))
        async let b = transport.send(URLRequest(url: .api("/feed")))
        _ = try await (a, b)
        XCTAssertEqual(stub.refreshCount, 1)
    }
}
EOF

# ───────────────────────── 단계 B: Codex ─────────────────────────
B=$R/stages/B
mkdir -p "$B/Moa/Login" "$B/MoaTests"
cp "$D/Moa/Login/LoginView.swift" "$B/Moa/Login/LoginView.swift"
perl -0pi -e 's/                .textContentType\(.password\)\n/                .textContentType(.password)\n            if let message = viewModel.errorMessage {\n                Text(message)\n                    .font(.footnote)\n                    .foregroundStyle(.red)\n            }\n/' "$B/Moa/Login/LoginView.swift"
cp "$D/Moa/Login/LoginViewModel.swift" "$B/Moa/Login/LoginViewModel.swift"
perl -0pi -e 's/            errorMessage = "로그인에 실패했습니다."\n        \}\n    \}\n/            errorMessage = Self.message(for: error)\n        }\n    }\n\n    static func message(for error: Error) -> String {\n        switch error {\n        case AuthError.sessionExpired: return "로그인이 만료됐어요. 다시 로그인해 주세요."\n        case AuthError.unauthorized: return "이메일 또는 비밀번호를 확인해 주세요."\n        default: return "잠시 후 다시 시도해 주세요."\n        }\n    }\n/' "$B/Moa/Login/LoginViewModel.swift"
cat > "$B/MoaTests/LoginErrorMessageTests.swift" <<'EOF'
import XCTest
@testable import Moa

@MainActor
final class LoginErrorMessageTests: XCTestCase {
    func testSessionExpiredAsksToSignInAgain() {
        XCTAssertEqual(LoginViewModel.message(for: AuthError.sessionExpired),
                       "로그인이 만료됐어요. 다시 로그인해 주세요.")
    }

    func testUnauthorizedPointsToCredentials() {
        XCTAssertEqual(LoginViewModel.message(for: AuthError.unauthorized),
                       "이메일 또는 비밀번호를 확인해 주세요.")
    }
}
EOF

# ───────────────────────── 사이드바용 다른 프로젝트 ─────────────────────────
S=$R/moa-server
G init -q "$S"; mkdir -p "$S/src/webhooks" "$S/src/cache"
printf 'export async function handlePaymentWebhook(event: PaymentEvent) {\n  await queue.enqueue(event);\n}\n' > "$S/src/webhooks/payment.ts"
printf 'export const orderCache = new Map<string, Order>();\n' > "$S/src/cache/orders.ts"
printf '{ "name": "moa-server", "private": true }\n' > "$S/package.json"
(cd "$S" && G add -A && GIT_AUTHOR_DATE="$(ago 5d)" GIT_COMMITTER_DATE="$(ago 5d)" G commit -q -m "서버 초기 구성")

W=$R/moa-web
G init -q "$W"; mkdir -p "$W/app"
printf 'export default function Page() {\n  return <main>Moa</main>;\n}\n' > "$W/app/page.tsx"
printf '{ "name": "moa-web", "private": true }\n' > "$W/package.json"
(cd "$W" && G add -A && GIT_AUTHOR_DATE="$(ago 6d)" GIT_COMMITTER_DATE="$(ago 6d)" G commit -q -m "웹 초기 구성")

echo "$R"
(cd "$D" && G log --oneline --decorate -5 && G status -sb)
