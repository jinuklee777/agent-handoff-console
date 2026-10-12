# Third-party notices

Agent Handoff Console is released under the [MIT License](LICENSE). The app includes the third-party code listed below. The license texts are copied verbatim from the files that ship inside the app bundle:

- `AgentHandoffConsole/Resources/LICENSE-SwiftTerm.txt`
- `AgentHandoffConsole/UI/Design/ThinkingOrbs/LICENSE-thinking-orbs.txt`

The app shows the same texts under Settings › About › Open source notices (설정 › 정보 › 오픈소스 고지…).

## SwiftTerm

- **Used for:** the terminal in the inspector's Terminal tab.
- **Source:** <https://github.com/migueldeicaza/SwiftTerm>, version 1.10.0 (revision `ca6f80ef534248d2f65c1b640656e3c9a270bfeb`, pinned in `Package.resolved`). Fetched by Swift Package Manager and linked into the app.
- **License:** MIT

```text
Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## thinking-orbs (ThinkingOrbsKit)

- **Used for:** the animated dot orb in the run status line.
- **Source:** <https://github.com/Jakubantalik/Libraries.dev>, `packages/thinking-orbs/ports/ios/ThinkingOrbsKit/Sources` at commit `d066408` (thinking-orbs spec 0.3.1). Copied without modification into `AgentHandoffConsole/UI/Design/ThinkingOrbs/`; `Snapshot.swift` was left out.
- **License:** MIT

```text
MIT License

Copyright (c) 2026 Jakub Antalik

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Resolved but not shipped

- **swift-argument-parser** 1.8.2 (<https://github.com/apple/swift-argument-parser>, Apache License 2.0 with Runtime Library Exception) appears in `Package.resolved` because a command-line target of SwiftTerm depends on it. It is not linked into the app.

## Trademarks and logos

To show which agent is speaking, the app draws the Claude and OpenAI logos (`AgentHandoffConsole/UI/Design/BrandMark.swift`) and shows the Antigravity logo (`AgentHandoffConsole/Resources/Assets.xcassets/AntigravityMark.imageset`). Claude and Claude Code are trademarks of Anthropic; OpenAI and Codex are trademarks of OpenAI; Google, Gemini and Antigravity are trademarks of Google. These logos and names belong to their owners. They are not covered by this project's MIT license and are used only to identify the corresponding agent. This project is not affiliated with or endorsed by Anthropic, OpenAI or Google.
