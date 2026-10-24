# Claude Code in CodeRelay

## Decision — 2026-10-23

The user requested embedded Claude Code support and approved separate continuations
of existing sessions. This supersedes the previous OpenCode-only product boundary.
OpenCode keeps its existing API, credentials, identifiers and persistence.

### Journeys and ownership

1. The host operator installs an optional, independent Claude adapter, configures
   trusted project roots and a dedicated adapter password, and exposes only its
   loopback listener through private Tailscale Serve. No production host is changed
   by developing or testing this feature.
2. The mobile user selects Claude Code when registering a machine, tests the
   adapter identity, and saves only that adapter's credentials in the existing vault.
   Claude provider credentials and subscription authentication stay on the host.
3. The user lists/searches local Claude sessions in authorized project roots and
   reads their history. Before continuing an external session, the app explicitly
   offers to fork its transcript using the official SDK. The original transcript
   is unchanged. **This does not fork or isolate project files.**
4. A managed session accepts one prompt at a time. The adapter commits a receipt
   to local SQLite before acknowledging admission; duplicate IDs with the same
   payload return that receipt, while different payloads conflict. There is no
   automatic replay after a crash or ambiguous response. The app reconciles by ID.
5. The official SDK runs Claude Code in default permission mode. Approval prompts
   and AskUserQuestion are answered from the phone; unanswered requests expire
   closed. Only one-time approvals are supported, not persistent grants.
6. Interrupt and shutdown stop owned execution, clear pending approvals, and record
   an interrupted outcome. After an unclean restart, nonterminal receipts become
   interrupted/unknown rather than executing again. Transcript persistence alone
   is not exactly-once execution or a durable job queue.

### Boundaries and contract

- Dedicated `/relay/v1` API identifying `agent: claude_code` and protocol version 1;
  it does not impersonate OpenCode routes or report an OpenCode version.
- Python official `claude-agent-sdk` for session enumeration, transcript reads,
  forks, `ClaudeSDKClient`, default permissions, input callbacks and interrupts.
- aiohttp handles authenticated HTTP. SQLite owns managed-session metadata,
  normalized displayed messages and prompt receipts, not provider credentials.
- Listener fixed to loopback, mandatory strong password, constant-time Basic Auth,
  no redirects/CORS/browser login, no access logging of prompts or credentials.
- Explicit host project-root allowlist gates session discovery, creation and
  resume. This controls adapter entry points, **not an OS sandbox for Claude tools**.
  Shell/tool approvals retain their normal host impact; use a dedicated OS user or
  sandbox for strong filesystem/process isolation.
- Admission is bounded globally and per session, with no in-memory waiting queue;
  429/409 reject excess work before starting an SDK task. Bodies, history pages,
  catalog discovery, SDK buffers, turn duration and approval waits have limits.
- SDK/project configuration is not silently inherited: settings sources are empty,
  MCP configuration is strict/empty, and no bypass or acceptEdits mode is enabled.
  Host-approved roots must contain trusted projects; managed enterprise policy may
  still apply. Future MCP/skills support requires a separate explicit contract.
- First release: create/list/search, read/fork existing history, text conversation,
  model selection, one-time approvals, questions, receipt reconciliation, interrupt.
  OpenCode-specific queues, agent selectors, pairing, attachments, file browser,
  MCP/skills management, context and snapshot diff remain unavailable for Claude
  and are hidden or rejected explicitly rather than shown as empty successes.

### Alternatives

Opening Anthropic Remote Control would be an external experience, not an embedded
integration. Pretending Claude speaks OpenCode would couple unrelated contracts.
Writing the terminal's active transcript was rejected in favor of the user-approved
fork. Parsing undocumented private transcript files was rejected in favor of SDK
session functions. Auto-approving tools or accepting an unlimited background queue
was rejected for safety and recovery semantics.

Revisit when the official SDK offers safe ownership transfer, interoperable
capabilities, or stronger session-sandbox primitives.

### Sources

- https://code.claude.com/docs/en/agent-sdk/python
- https://code.claude.com/docs/en/agent-sdk/sessions
- https://code.claude.com/docs/en/agent-sdk/permissions
- https://code.claude.com/docs/en/agent-sdk/user-input

Paid/authenticated provider execution requires separate operator authorization;
local tests must not use the operator's credentials or incur provider charges.
