# Claude widget validation — 2026-10-21

Production sources and packaged native helpers were exercised without modifying
real Claude Code configuration or sending a paid Claude request.

- `AGENTNOTCH_TEST_SCOPE=claude bash Tests/run.sh`: **96/96** Swift component
  cases passed. The runner also passed **9/9 Codex + 13/13 Claude** native helper
  Python cases and the existing native media serialization checks.
- `AGENTNOTCH_TEST_SCOPE=desktop bash Tests/run.sh`: **134/140** Swift cases
  passed, including Claude/Codex persistence, reorder, compact-wing geometry,
  localization, store, lifecycle, runtime identity and installer cases. Six
  existing native file drag/pasteboard cases failed because this restricted
  shell cannot write to the desktop pasteboard. This scope omits the app entry
  and settings macro files; Xcode separately built the complete application.
- Complete app: **Xcode desktop Build/Run succeeded**, `My Mac`, Debug. Shell
  `xcodebuild` hit the environment's SwiftUI macro plugin sandbox restriction;
  the same sources compiled through Xcode. `codesign --verify --deep --strict`
  passed for the resulting app, including the packaged Claude helper.
- Real App Sandbox: added Claude through the actual widget catalog. The real
  Claude process's registry row appeared using native process owner/start-time
  validation. No credential or transcript grant was added. Widget-to-Claude
  settings navigation and cancel-without-installation were checked live.
- Presentation: actual 414×180 pt SwiftUI cards were rendered and visually
  inspected in Turkish and English for disconnected, working/subagent,
  permission and stale/unknown data. A live preview window additionally verified
  actual scroll content and agent rows. ImageRenderer omits scroll contents in
  this environment, so agent rows were verified in the actual preview window
  and shipping application rather than inferred from static PNGs.
- Signed isolated sandbox fixture: **15/15** checks passed for exact
  `settings.json` + own-directory grants, atomic replacement, installer
  idempotence, removal/restoration, preservation of foreign hooks/statusline,
  denied credential access and denied unrelated writes. **2/2** external-shell
  checks then passed for hook delivery and captured quota with unchanged previous
  statusline stdout. All fixture paths are temporary.
- `plutil -lint`, shell syntax and `git diff --check` passed.

No live subscription percentage was invented or requested. A real quota lifecycle
still requires the user to connect and send a message in a new trusted Claude Code
session. API/provider-backed sessions may legitimately omit subscription limits.
The private runtime registry remains version-sensitive; unknown schemas are
ignored. This is a tested local integration, not a guarantee against future
Claude Code or macOS changes.
