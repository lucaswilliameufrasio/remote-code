# Chat history and question flow

**Status:** implemented, 2026-10-14

## Context

The chat refreshed up to 200 messages every three seconds, even while idle. It
also replaced the loaded history on each refresh. Agent questions appeared as a
small generic list item, and answer forms used a constrained alert dialog with
no write-in option for choice fields.

The installed OpenCode v2.0.27 OpenAPI specification confirms that
`GET /api/session/{sessionID}/message` accepts `limit`, `order`, and an opaque
`cursor`; the response exposes the next cursor. This is the pagination contract
used by the client. The OpenCode question-tool guidance also describes custom
answers and navigating between multiple questions.

## Decision

- Load 30 recent messages when opening a session. Poll only the 12 newest while
  the session is open: every three seconds during execution and every ten seconds
  while idle.
- Fetch 30 older messages by cursor when the user reaches the older edge or taps
  “Carregar mensagens anteriores”. Merge pages by message ID so polling can update
  a still-generating message without discarding older pages. Send `order=desc` on
  the initial page only; OpenCode v2 requires cursor requests to omit `order`.
- Keep pending requests visible above the conversation. Put questions before
  permissions, show the form and first question text, and provide an explicit
  “Responder agora” action.
- Present a multi-field form in a scrollable bottom sheet, one question at a time,
  with progress, back/next controls, and a persistent submit action. Choice fields
  accept either a listed option or a typed answer; multi-select answers can include
  an additional typed value. Preserve the v2 reply body `{ answer: { ... } }`.

## Trade-offs and follow-up

Opaque cursors avoid offsets and make older-page requests proportional to the page
size. Polling still retransmits a bounded recent window so a message being
generated can be refreshed; the idle interval is longer to reduce mobile traffic.
Validate cursor behavior, write-in answers, and keyboard resizing against a real
OpenCode server on Android and iOS before distribution.

## References

- [OpenCode server API](https://opencode.ai/docs/server/)
- [OpenCode question tool](https://opencode.ai/docs/tools/#question)
