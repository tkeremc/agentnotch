# Claude Code widget research

Researched on 2026-10-21 against current Anthropic documentation and the locally
installed Claude Code **2.1.305**. Only schema and lifecycle metadata were
inspected. No credentials, conversation bodies, or identifying session data are
included here. Research did not change the user's Claude configuration.

## Supported quota contract

Claude's `statusLine` command receives JSON on stdin. Subscription quota uses
`rate_limits.five_hour` and `rate_limits.seven_day`; each contains
`used_percentage` (0–100) and `resets_at` (Unix **seconds**). The fields appear for
Pro/Max accounts after an API response; absence must remain unavailable. Gateway
`spend_limit` is a different budget and must not be mislabeled as subscription
quota. Context occupancy and token statistics are also separate measurements.

A status line runs during startup, assistant updates, compaction, permission-mode
changes, scheduled refreshes, and reset boundaries. It can run while idle and is
**never evidence of active work**. It runs locally without consuming tokens.
Concurrent terminals can hold different cached account observations; display the
latest observation, expire it, and never infer zero consumption from a reset.
No account identity is available in the selected contract, so simultaneous
different-account sessions in one config directory cannot be separated reliably.

Source: [Anthropic statusline reference](https://code.claude.com/docs/en/statusline).

## Supported lifecycle contract

Hooks carry `session_id`, `cwd`, and `hook_event_name`; child events additionally
carry `agent_id`/`agent_type`. `UserPromptSubmit` begins work.
`PreToolUse` supplies `tool_use_id`; `PermissionRequest` supplies tool name/input
but **no tool ID**. Match requests conservatively against preceding tool calls.
`PostToolUse`/`PostToolUseFailure` resolve matching requests.

`PermissionRequest` is immediate. `Notification(permission_prompt)` is delayed
and covers sandbox network prompts omitted by PermissionRequest. `PermissionDenied`
only describes auto-mode denials. A user's rejection has no universal resolution
hook. `Stop` does not fire on interruption; API errors use `StopFailure`.

`SubagentStart` can repeat on resume. Track children by session plus agent ID;
child events must not complete the parent. `SubagentStop` carries a separate
`agent_transcript_path`. A main `Stop` may include running `background_tasks`;
parent completion does not imply child completion. `SessionEnd` closes a session.
Observers must return success with empty stdout and make no permission decisions.
Other hooks can prevent stopping, so a stop observation is not proof that every
other observer agreed to finish.

Source: [Anthropic hook reference](https://code.claude.com/docs/en/hooks).

## Passive runtime fallback: locally verified, private format

Current Claude writes `<config>/sessions/<pid>.json`. The observed shape includes:

| Field | Interpretation |
| --- | --- |
| `pid`, filename | Native process ID; both must agree |
| `sessionId` | Associates the process with a main session |
| `cwd` | Project directory; show only the final component |
| `status` | Current UI lifecycle state |
| `statusUpdatedAt` | Status observation time, Unix **milliseconds** |
| `updatedAt` | Also changes for unrelated metadata; not work evidence |
| `startedAt` | Registry process start, Unix milliseconds |
| `procStart` | Native process identity string in UTC for detecting PID reuse |
| `pidDomain` | PID namespace; only local macOS records are eligible |
| `waitingFor` | Optional wait reason; private strings may change |

Inspection of the installed executable's presence-state implementation confirmed
that `waiting` means a pending interaction, `busy` means the main process is
loading or delegated work is active, and the remaining main state is `idle`.
The writer upgrades idle to `shell` while background shell tasks remain active.
An idle session can stay open in a terminal. Its existence is not active work.
The widget labels it Ready / Hazır, without implying that a task completed.

Observed wait reasons include `permission prompt`, `goal proposal`,
`input needed`, `worker request`, `sandbox request`, and `dialog open`. A wait
cannot universally be called a permission request. In particular, do not compare
only against `permission`: that is not the observed permission string. Preserve
hook evidence while a matching wait remains unresolved; newer busy/idle evidence
can clear an obsolete permission indication.

Validate the native process owner and start time before trusting a registry PID.
The installed implementation generates its identity with
`LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`; native start timestamps must therefore
be formatted in UTC, not the user's local timezone, before comparison.
PID existence alone permits reuse errors. Process inspection denied by the OS
means unverifiable, not a confirmed exit. Skip unsupported PID namespaces and
unrecognized records. Files can be stale after crashes, and status writes are
asynchronous. Compare `statusUpdatedAt` with hook timestamps and reject future
observations. The current writer updates status on state changes, not a periodic
heartbeat: a long-running tool or unanswered permission can retain its timestamp
for many minutes. Do not discard an otherwise verified live process's state
merely because this timestamp is old. Age out hook-only observations separately.
Never use file modification time as an active heartbeat.

This registry is **not a documented public API**. It is an optional fallback, not
a replacement for supported events. Conservative unknown states are intentional.
The local sample was idle; no paid request or synthetic prompt was sent to create
an active session. Native process inspection in the development sandbox can be
restricted, so synthetic tests and an actual user-run lifecycle exercise remain
different levels of validation.

## Integration and user experience

The widget starts with local observation. Enabling its official event integration
is a deliberate in-app action that installs a bounded native helper and merges
only its own hook entries into user settings. It requires no additional login,
API key, OAuth token, browser cookie, or polling request to Anthropic.

Existing statusline configuration must survive. Wrap the previous command,
forward its original stdin, preserve its stdout and extra configuration fields,
and restore it when removing an unchanged integration. The helper's separate
private event spool contains only bounded lifecycle/quota metadata and tool-input
hashes, never raw prompts, tool arguments, or transcript text. Statusline forwarding
is time/output bounded, so a slow existing script may be cut short.

Default config is the real user's `~/.claude`; honor an absolute
`CLAUDE_CONFIG_DIR` when supplied. Project/local/managed settings can override user
settings, and organizational policy can disable hooks. Claude's workspace trust
decision is still required and belongs to Claude. Until events arrive, the app
must communicate waiting/unavailable rather than fabricate quota or activity.
Removing the widget stops polling; removing the connection restores owned
configuration without deleting unrelated settings.

Source: [Anthropic settings reference](https://code.claude.com/docs/en/settings).

## Assets

The monochrome Claude mark retains the original Lobe Icons vector path. It is
rendered as a native template, with the existing MIT attribution in
`Design/ThirdParty`. Source:
[Lobe Icons Claude Mono](https://github.com/lobehub/lobe-icons/blob/master/src/Claude/components/Mono.tsx).
