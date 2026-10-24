# CodeRelay Claude Code adapter

Optional host component for the **Claude Code** backend in CodeRelay. Uses the
official Python Agent SDK, not OpenCode routes, not a terminal screen scraper.
Requires Python **3.11+**, macOS or Linux, and host-side Claude authentication
supported by the Agent SDK. Provider billing/authentication is independent of the
adapter's HTTP password. A successful connection test checks the adapter identity,
not whether the provider subscription, model or balance permits a paid turn.

## Install and run

From the repository, run `make setup-claude`. This creates only
`host/claude-code/.venv`; it does not install a daemon or modify OpenCode.

Configure provider credentials using your approved host-side secret mechanism
and the [official SDK authentication documentation](https://code.claude.com/docs/en/agent-sdk/quickstart).
Do not put an Anthropic API key, OAuth token, subscription password or recovery
phrase into CodeRelay's machine form. Never copy provider credentials to the phone.

Use a dedicated, randomly generated adapter password of at least 24 characters.
With Bash/Zsh, enter it without echoing or writing it to command history:

```sh
printf 'Adapter password: '
read -s CODERELAY_ADAPTER_PASSWORD
printf '\n'
export CODERELAY_ADAPTER_PASSWORD
host/claude-code/.venv/bin/python host/claude-code/server.py \
  --root "$HOME/projects" \
  --state-directory "$HOME/.local/state/coderelay-claude" \
  --port 4097
unset CODERELAY_ADAPTER_PASSWORD
```

Use an existing, canonical, trusted project root (not `/`, a symlink, or a path
containing `..`). Repeat `--root` for up to 16 roots. The SQLite state directory
must be private (0700); database permissions are 0600. Keep it outside project
repositories and back it up using the same protections as conversation history.
The SDK persists its own Claude transcripts in its normal host-side store.
No prompts or credentials are written to HTTP access logs.

The adapter listens **only on 127.0.0.1** and defaults to port 4097. In another
terminal, inspect `tailscale serve status` first. Configure a **private Serve**
listener for this port without replacing existing application routes. For example,
if HTTPS port 8443 is unused:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:4097
```

This is **not Funnel**. The phone needs Tailscale connected. Do not reset existing
routes, expose a public listener, install a service or modify production hosts
without separate authorization. Shut down this foreground adapter with Ctrl-C;
remove only its Serve listener when no longer needed, preserving other services.

## Connect from the app

1. Add a machine and choose **Claude Code**.
2. Enter the HTTPS URL of this adapter's private Tailscale Serve listener.
3. User: `coderelay`. Password: the dedicated adapter password above.
4. Test, then save. Local credentials use CodeRelay's existing secure vault.
5. Browse sessions or create one in an authorized directory. Terminal sessions open
   in read-only mode. **Continue in CodeRelay** asks before creating an official SDK
   fork. Only the transcript is copied; project files are still shared.

To use both agents on the same computer, add separate machine profiles. The
backend of an existing profile is fixed so its saved session IDs and shortcuts
cannot silently be reinterpreted as sessions belonging to another agent.

Supported: authorized local session discovery/search and history, new sessions,
forked continuations, text prompts, default/sonnet/opus/haiku model aliases,
one-time allow/deny, AskUserQuestion, interrupt and exact prompt receipts.
Model availability depends on the host account/provider; no model is claimed to
be enabled by the connection health check.

Not supported for Claude in this release: pairing/QR, attachments, OpenCode agents,
background message queue, permanent permission grants, MCP/skills management,
restricted file browser, context inspection and OpenCode snapshot diffs. These
controls are hidden and direct unsupported calls fail instead of falling back to
OpenCode. Existing OpenCode machines retain their original features.

## Safety and delivery guarantees

- One active turn per session, two globally. Excess work gets 409/429; there is
  no pending worker queue. HTTP bodies are limited to 128 KiB, text to 64 KiB,
  concurrent authenticated requests to 32, tool approval input to 32 KiB, and
  outstanding approval requests to 32.
- Turn deadline: 15 minutes/40 agentic turns. Approval deadline: 3 minutes, then
  deny. No bypassPermissions or acceptEdits mode. SDK default-mode operations
  that require no approval (for example ordinary project reads) may run normally.
- Default settings sources are disabled and MCP configuration is strict/empty;
  host hooks, plugins and user/project allow rules are not deliberately enabled.
  Enterprise-managed policies and the SDK's documented unconditional inputs may
  still apply. Only use trusted project roots.
- Root checks constrain adapter entry points and session visibility, **not the
  tools' OS privileges**. Bash and approved tools can have effects outside the
  project. A dedicated OS user/container/sandbox is needed for stronger isolation.
- A receipt is committed to SQLite before 202. A duplicate ID with identical
  payload returns the original receipt; a different payload gets 409. The app
  checks that exact ID after a missing acknowledgement. It never retries blindly.
- Receipts distinguish admitted/running/completed/failed/interrupted. Restart
  turns nonterminal receipts into interrupted, with a visible message. Nothing
  is automatically replayed. Interrupt/disconnect do not revert existing file
  changes or promise exactly-once tool effects.
- At most 1000 managed sessions, 10000 receipts, approximately 256 MiB of SQLite,
  5000 messages per session and 8 MiB per import. Discovery considers the newest
  5000 local SDK sessions and authorized roots. Collections are paginated (up to
  100 per request); timestamps are UTC Unix milliseconds, matching mobile models.
- Protect the host as a single-user remote coding endpoint. This is not a
  multi-user isolation service, public API or production internet-facing gateway.
  A process lock prevents two adapters from owning the same SQLite state directory.

## HTTP contract

All routes require Basic Auth, return `Cache-Control: no-store`, and are under
`/relay/v1`. Errors use `{error_code, message}`; 422 also includes
`extra.validation_errors`. Missing optional keys are omitted. Collections use
`{data, has_more, next_cursor?}`. Cursors are opaque to the app.

| Method / resource | Purpose |
| --- | --- |
| `GET /info` | Agent/protocol identity and readiness, not provider authentication |
| `GET /projects` | Configured trusted roots |
| `GET /sessions?search=&directory=&limit=&cursor=` | Authorized, paginated catalog |
| `POST /sessions` | Create metadata with `{title, directory}`, without a model call |
| `GET /sessions/{id}` | Managed or authorized external session metadata |
| `POST /sessions/{id}/fork` | `{confirm_shared_files: true}`; explicit transcript fork |
| `GET /sessions/{id}/messages?limit=&cursor=` | Chronological display page, cursor towards older messages |
| `POST /sessions/{id}/prompts` | `{id, text, model?}`; durable receipt before 202 |
| `GET /sessions/{id}/receipts/{id}` | Exact admission/outcome lookup, 404 if not recorded |
| `GET /active` | Adapter-owned active turns, not other terminals' activity |
| `GET /requests?kind=&directory=` | Outstanding permission/question callbacks |
| `GET /sessions/{id}/requests?kind=` | Session-specific callbacks |
| `POST /sessions/{id}/requests/{id}/reply` | `{reply: once/reject}` or `{answers: {...}}` |
| `POST /sessions/{id}/interrupt` | Interrupt/cancel the adapter-owned turn |

Interrupted or failed receipts mean **admitted but not successfully completed**,
not "safe to resend". Duplicate prompt IDs never restart a recorded turn. Store
session IDs as UUIDs and prompt IDs as opaque strings of up to 128 safe characters.

## Verification

`make test-claude` runs real HTTP, SQLite, permissions, overload, restart and
idempotency tests, plus the **real bundled Claude CLI/SDK** against a loopback
Anthropic-protocol fixture. The model boundary is synthetic; no provider charge,
operator credentials, host sessions or production files are used. `make validate`
includes these tests after `make setup-claude`.

With a booted iOS Simulator, `make test-claude-local-app DEVICE=<simulator-id>`
also drives the real Flutter client through fork confirmation, text submission
and an SDK permission denial over HTTPS. A generated test CA is trusted only by
that test client's SecurityContext; device/system trust and production ATS stay
unchanged. Fixture listeners, transcripts, credentials and certificates are
temporary and removed when the runner exits.

Design and protocol rationale: [integration decision](../../docs/claude-code-integration.md).
